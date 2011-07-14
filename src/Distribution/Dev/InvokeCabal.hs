{-# LANGUAGE CPP #-}
module Distribution.Dev.InvokeCabal
    ( actions
    , setup
    , extraArgs
    , cabalArgs
    )
where

import Control.Applicative ( (<$>) )
import Distribution.Verbosity ( Verbosity, showForCabal )
import Distribution.Simple.Program ( Program( programFindLocation )
                                   , ConfiguredProgram
                                   , emptyProgramConfiguration
                                   , locationPath
                                   , programLocation
                                   , requireProgram
                                   , runProgram
                                   , simpleProgram
                                   )
import Distribution.Simple.Utils ( writeUTF8File, debug, cabalVersion
                                 , readUTF8File )
import Distribution.ParseUtils ( ParseResult(..), Field, readFields )
import Distribution.Version ( Version(..) )
import System.Console.GetOpt  ( OptDescr )

import Distribution.Dev.Command            ( CommandActions(..)
                                           , CommandResult(..)
                                           )
import Distribution.Dev.Flags              ( Config, getCabalConfig
                                           , getVerbosity, passthroughArgs
                                           , cfgCabalInstall
                                           )
import Distribution.Dev.InitPkgDb          ( initPkgDb )
import qualified Distribution.Dev.RewriteCabalConfig as R
import qualified Distribution.Dev.CabalInstall as CI
import Distribution.Dev.Sandbox            ( resolveSandbox
                                           , cabalConf
                                           , Sandbox
                                           , KnownVersion
                                           , PackageDbType(..)
                                           , getVersion
                                           , pkgConf
                                           , sandbox
                                           )
import Distribution.Dev.Utilities          ( ensureAbsolute )
import Distribution.Dev.MergeCabalConfig   ( mergeFields )

actions :: CI.CabalCommand -> CommandActions
actions cc = CommandActions
              { cmdDesc = "Invoke cabal-install with the development configuration"
              , cmdRun = \flgs _ args -> invokeCabal flgs cc args
              , cmdOpts = [] :: [OptDescr ()]
              , cmdPassFlags = True
              }

invokeCabal :: Config -> CI.CabalCommand -> [String] -> IO CommandResult
invokeCabal flgs cc args = do
  let v = getVerbosity flgs
  cabal <- CI.findOnPath v $ cfgCabalInstall flgs
  res <- cabalArgs cabal flgs cc
  case res of
    Left err -> return $ CommandError err
    Right args' -> do
             runProgram v cabal $ args' ++ args
             return CommandOk

cabalArgs :: ConfiguredProgram -> Config -> CI.CabalCommand -> IO (Either String [String])
cabalArgs cabal flgs cc = do
  let v = getVerbosity flgs
  s <- initPkgDb v =<< resolveSandbox flgs
  setup s cabal flgs cc

readConfig :: String -> Either String [Field]
readConfig s = case readFields s of
                 ParseOk _ fs  -> Right fs
                 ParseFailed e -> Left $ show e

-- XXX: we should avoid this lazy IO that leaks a file handle.
readConfigF :: FilePath -> IO (Either String [Field])
readConfigF fn =
    (readConfig <$> readUTF8File fn) `catch` \e -> return $ Left $ show e

getUserConfigFields :: CI.CabalFeatures -> IO [Field]
getUserConfigFields fs =
    -- If we fail to read the file, then it could be that it doesn't yet
    -- exist, and it's OK to ignore.
    either (const []) id <$> (readConfigF =<< CI.getUserConfig fs)

getDevConfigFields :: Config -> IO [Field]
getDevConfigFields cfg =
    either error id <$> (readConfigF =<< getCabalConfig cfg)

setup :: Sandbox KnownVersion -> ConfiguredProgram -> Config ->
         CI.CabalCommand -> IO (Either String [String])
setup s cabal flgs cc = do
  let v = getVerbosity flgs
  devFields <- getDevConfigFields flgs
  cVer <- CI.getFeatures v cabal
  let cfgOut = cabalConf s
  case cVer of
    Left err -> return $ Left err
    Right features -> do
      userFields <- getUserConfigFields features
      cabalHome <- CI.configDir features
      let rew = R.Rewrite cabalHome (sandbox s) (pkgConf s) (CI.needsQuotes features)
          cOut = show $ R.ppTopLevel $ concat $
                 R.rewriteCabalConfig rew $
                 mergeFields userFields devFields

      writeUTF8File cfgOut cOut
      (gOpts, cOpts) <- extraArgs v cfgOut (getVersion s)
      let gFlags = map toArg gOpts
          cFlags = map toArg $ filter (CI.supportsLongOption cc . fst) cOpts
          args = concat
                 [ -- global cabal-install flags, as
                   -- generated by cabal-dev
                   gFlags

                 -- The cabal command name
                 , [ CI.commandToString cc ]

                 -- command-specific flags, as generated
                 -- by cabal-dev
                 , cFlags

                 -- Arguments that the user specified
                 -- that we pass through
                 , passthroughArgs flgs
                 ]

      debug v $ "Complete arguments to cabal-install: " ++ show args
      return $ Right args

toArg :: Option -> String
toArg (a, mb) = showString "--" .
                showString a $ maybe "" ('=':) mb

-- option name, value
type Option = (String, Maybe String)
type Options = [Option]

extraArgs :: Verbosity -> FilePath -> PackageDbType -> IO (Options, Options)
extraArgs v cfg pdb =
    do pdbArgs <- getPdbArgs
       return ([cfgFileArg], verbosityArg:pdbArgs)
    where
      longArg s = (,) s . Just
      cfgFileArg = longArg "config-file" cfg
      verbosityArg = longArg "verbose" $ showForCabal v
      withGhcPkg = longArg "with-ghc-pkg"
      getPdbArgs =
          case pdb of
            (GHC_6_8_Db loc) | needsGHC68Compat -> do
                     -- Make Cabal call the wrapper that removes the
                     -- bad argument to ghc-pkg 6.8
                     debug v $ "Using GHC 6.8 compatibility wrapper for Cabal shortcoming"
                     (ghcPkgCompat, _) <-
                         requireProgram v ghcPkgCompatProgram emptyProgramConfiguration
                     return $ [ longArg "ghc-pkg-options" $ toArg $ withGhcPkg loc
                              , withGhcPkg $ locationPath $
                                programLocation ghcPkgCompat
                              ]
            _ -> return []

-- XXX: this is very imprecise. Right now, we require a specific
-- version of Cabal, so this is ok (and is equivalent to True). Note
-- that this is the version of Cabal that THIS PROGRAM is being built
-- against, rather than the version that CABAL-INSTALL was built
-- against.
needsGHC68Compat :: Bool
needsGHC68Compat = cabalVersion < Version [1, 9] []

ghcPkgCompatProgram :: Program
ghcPkgCompatProgram  = p { programFindLocation =
                           \v -> do
                             res <- programFindLocation p v
                             case res of
                               Nothing -> return Nothing
                               Just loc -> Just `fmap` ensureAbsolute loc
                         }
    where
      p = simpleProgram "ghc-pkg-6_8-compat"
