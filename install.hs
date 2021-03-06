#!/usr/bin/env stack
{- stack
  --stack-yaml shake.yaml
  --install-ghc
  runghc
  --package shake
  --package tar
  --package zlib
-}

import qualified Data.ByteString.Lazy          as BS
import qualified Codec.Archive.Tar             as Tar
import qualified Codec.Compression.GZip        as GZip

import           Development.Shake
import           Development.Shake.Command
import           Development.Shake.FilePath
import           Control.Monad
import           System.Environment             ( getProgName
                                                , unsetEnv
                                                )
import           System.Info                    ( os
                                                , arch
                                                )

import           Data.List                      ( dropWhileEnd
                                                , intersperse
                                                )
import           Data.Char                      ( isSpace )

type VersionNumber = String
type GhcPath = String

-- |Defines all different hie versions that are buildable.
-- If they are edited, make sure to maintain the order of the versions.
hieVersions :: [VersionNumber]
hieVersions =
  ["8.2.1", "8.2.2", "8.4.2", "8.4.3", "8.4.4", "8.6.1", "8.6.2", "8.6.3"]

-- |Most recent version of hie.
-- Important for `dist`, the `hie-wrapper` of the most recent hie
-- will be copied to the tar-archive.
mostRecentHieVersion :: VersionNumber
mostRecentHieVersion = last hieVersions

main :: IO ()
main = do
  -- unset GHC_PACKAGE_PATH for cabal
  unsetEnv "GHC_PACKAGE_PATH"
  shakeArgs shakeOptions { shakeFiles = "_build" } $ do
    want ["help"]
    phony "ghc" $ do
      ghc <- getGhcPath
      command_ [] ghc ["--version"]
      liftIO $ putStrLn "GHC"
    phony "submodules" updateSubmodules
    phony "cabal"      (getGhcPath >>= installCabal)
    phony "all"        helpMessage
    phony "help"       helpMessage
    phony "build"      (need (reverse $ map ("hie-" ++) hieVersions))
    phony "build-all"  (need ["build"] >> need ["build-docs"])
    phony "dist"       buildDist
    phony "build-docs" (need (reverse $ map ("build-doc-hie-" ++) hieVersions))
    phony "test"       (forM_ hieVersions test)
    phony "build-copy-compiler-tool" $ forM_ hieVersions buildCopyCompilerTool

    forM_ hieVersions
          (\version -> phony ("build-doc-hie-" ++ version) $ buildDoc version)

    forM_
      hieVersions
      (\version -> phony ("hie-" ++ version) $ do
        need ["submodules"]
        need ["cabal"]
        buildHie version
        installHie version
      )

    phony "icu-macos-fix"
          (need ["icu-macos-fix-install"] >> need ["icu-macos-fix-build"])
    phony "icu-macos-fix-install" (command_ [] "brew" ["install", "icu4c"])
    phony "icu-macos-fix-build" $ mapM_ buildIcuMacosFix hieVersions

-- |Creates a compressed tar-archive consisting of all hie versions and `hie-wrapper`.
-- Creates a temporary folder, copies all hie versions to it and compresses it in the end.
buildDist :: Action ()
buildDist = do
  need ["submodules"]
  need ["cabal"]
  -- Create the name of the resulting tar file.
  Stdout gitRef' <- command [] "git" ["describe", "--tags"]
  let gitRef      = trim gitRef'
  let hieDistName = concat ["hie-", gitRef, "-", arch, "-", os]
  -- define name constants for later use
  let hieWrapper  = "hie-wrapper" <.> exe
  let hie         = "hie" <.> exe
  let mkHie version = "hie-" ++ version <.> exe

  withTempDir
    (\temporaryDir -> do
      forM_ hieVersions $ \hieVersion -> do
        buildHie hieVersion
        -- after building `hie` copy it to the temporary folder
        localInstallRoot <- getLocalInstallRoot hieVersion
        copyFile' (localInstallRoot </> "bin" </> hie)
                  (temporaryDir </> mkHie hieVersion)

        -- if the most recent hie-* version is copied,
        -- copy it again as the default hie version
        -- Also, add its hie-wrapper to the tar archive
        when (hieVersion == mostRecentHieVersion) $ do
          copyFile' (localInstallRoot </> "bin" </> hieWrapper)
                    (temporaryDir </> hieWrapper)
          copyFile' (localInstallRoot </> "bin" </> hie) (temporaryDir </> hie)

      -- After every hie has been built, pack them into a tar.
      -- Encrypt the resulting tar file with gzip
      liftIO
        $   BS.writeFile (hieDistName ++ ".tar.gz")
        .   GZip.compress
        .   Tar.write
        =<< Tar.pack temporaryDir (hieWrapper : hie : map mkHie hieVersions)
    )
  return ()

buildIcuMacosFix :: VersionNumber -> Action ()
buildIcuMacosFix version = execStackWithYaml_
  version
  [ "build"
  , "text-icu"
  , "--extra-lib-dirs=/usr/local/opt/icu4c/lib"
  , "--extra-include-dirs=/usr/local/opt/icu4c/include"
  ]

updateSubmodules :: Action ()
updateSubmodules = do
  command_ [] "git" ["submodule", "sync", "--recursive"]
  command_ [] "git" ["submodule", "update", "--init", "--recursive"]

installCabal :: GhcPath -> Action ()
installCabal ghc = do
  execStack_ ["install", "cabal-install"]
  execCabal_ ["update"]
  execCabal_ ["install", "Cabal-2.4.1.0", "--with-compiler=" ++ ghc]

buildHie :: VersionNumber -> Action ()
buildHie versionNumber = do
  when (versionNumber `elem` ["hie-8.2.2", "hie-8.2.1"])
    $ execStackWithYaml_ versionNumber ["install", "happy"]
  execStackWithYaml_ versionNumber ["build"]
    `actionOnException` liftIO (putStrLn buildFailMsg)

buildFailMsg :: String
buildFailMsg =
  let starsLine
        = "\n******************************************************************\n"
  in  starsLine
        ++ "building failed, "
        ++ "try running `stack clean` and restart the build\n"
        ++ "if this does not work, open an issue at \n"
        ++ "https://github.com/haskell/haskell-ide-engine"
        ++ starsLine

installHie :: VersionNumber -> Action ()
installHie versionNumber = do
  execStackWithYaml_ versionNumber ["install"]
  localBinDir      <- getLocalBin
  localInstallRoot <- getLocalInstallRoot versionNumber
  let hie = "hie" <.> exe
  copyFile' (localInstallRoot </> "bin" </> hie)
            (localBinDir </> "hie-" ++ versionNumber <.> exe)
  copyFile' (localInstallRoot </> "bin" </> hie)
            (localBinDir </> "hie-" ++ dropExtension versionNumber <.> exe)

buildCopyCompilerTool :: VersionNumber -> Action ()
buildCopyCompilerTool versionNumber =
  execStackWithYaml_ versionNumber ["build", "--copy-compiler-tool"]

test :: VersionNumber -> Action ()
test versionNumber = execStackWithYaml_ versionNumber ["test"]

buildDoc :: VersionNumber -> Action ()
buildDoc versionNumber = do
  execStackWithYaml_ versionNumber ["install", "hoogle"]
  execStackWithYaml_ versionNumber ["exec", "hoogle", "generate"]

helpMessage :: Action ()
helpMessage = do
  scriptName <- liftIO getProgName
  out ""
  out "Usage:"
  out' ("stack " <> scriptName <> " <target>")
  out ""
  out "Targets:"
  mapM_ (out' . showTarget) targets
  out ""
 where
  out  = liftIO . putStrLn
  out' = out . ("    " ++)
  -- |Number of spaces the target name including whitespace should have.
  -- At least twenty, maybe more if target names are long. At most length of the longest target plus five.
  space :: Int
  space = maximum (20 : map ((+ 5) . length . fst) targets)

  -- |Show a target.
  -- Concatenates the target with its help message and inserts whitespace between them.
  showTarget :: (String, String) -> String
  showTarget (target, msg) =
    target ++ replicate (space - length target) ' ' ++ msg

  -- |Target for a specific ghc version
  hieTarget :: String -> (String, String)
  hieTarget version =
    ("hie-" ++ version, "Builds hie for GHC version " ++ version ++ " only")

  allVersionMessage :: String
  allVersionMessage =
    let msg         = intersperse ", " hieVersions
        lastVersion = last msg
    in  concat $ (init $ init msg) ++ [" and ", lastVersion]

  -- All targets with their respective help message.
  targets =
    [ ( "build"
      , "Builds hie for all supported GHC versions ("
      ++ allVersionMessage
      ++ ")"
      )
      , ( "build-all"
        , "Builds hie and hoogle databases for all supported GHC versions"
        )
      , ("cabal", "NOTE 3: This is needed for stack only projects too")
      , ( "build-docs"
        , "Builds the Hoogle database for all supported GHC versions"
        )
      , ("test"         , "Runs hie tests")
      , ("icu-macos-fix", "Fixes icu related problems in MacOS")
      , ("dist", "Creates a tarball containing all the hie binaries")
      , ("help"         , "Show help")
      ]
      ++ map hieTarget hieVersions

execStackWithYaml_ :: VersionNumber -> [String] -> Action ()
execStackWithYaml_ versionNumber args = do
  let stackFile = "stack-" ++ versionNumber ++ ".yaml"
  command_ [] "stack" (("--stack-yaml=" ++ stackFile) : args)

execStackWithYaml :: CmdResult r => VersionNumber -> [String] -> Action r
execStackWithYaml versionNumber args = do
  let stackFile = "stack-" ++ versionNumber ++ ".yaml"
  command [] "stack" (("--stack-yaml=" ++ stackFile) : args)

execStack :: CmdResult r => [String] -> Action r
execStack = command [] "stack"

execStack_ :: [String] -> Action ()
execStack_ = command_ [] "stack"

execCabal_ :: [String] -> Action ()
execCabal_ = command_ [] "cabal"

-- |Get the path to the GHC compiler executable linked to the local `stack.yaml`
-- Equal to the command `stack path --compiler-exe`
getGhcPath :: Action GhcPath
getGhcPath = do
  Stdout ghc' <- execStack ["path", "--compiler-exe"]
  return $ trim ghc'

-- |Read the local install root of the stack project specified by the VersionNumber
-- Returns the filepath of the local install root.
-- Equal to the command `stack path --local-install-root`
getLocalInstallRoot :: VersionNumber -> Action FilePath
getLocalInstallRoot hieVersion = do
  Stdout localInstallRoot' <- execStackWithYaml
    hieVersion
    ["path", "--local-install-root"]
  return $ trim localInstallRoot'

-- |Get the local binary path of stack.
-- Equal to the command `stack path --local-bin`
getLocalBin :: Action FilePath
getLocalBin = do
  Stdout stackLocalDir' <- execStack ["path", "--local-bin"]
  return $ trim stackLocalDir'

-- |Trim the end of a string
trim :: String -> String
trim = dropWhileEnd isSpace
