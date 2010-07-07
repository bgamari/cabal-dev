{-# LANGUAGE GADTs, EmptyDataDecls #-}
module Distribution.Dev.Sandbox
    ( KnownVersion
    , PackageDbType(..)
    , Sandbox
    , UnknownVersion
    , cabalConf
    , defaultSandbox
    , getSandbox
    , getVersion
    , indexTar
    , indexTarBase
    , localRepoPath
    , newSandbox
    , pkgConf
    , resolveSandbox
    , sandbox
    , setVersion
    )
where

import Control.Monad             ( unless )
import Data.Maybe                ( listToMaybe )
import Distribution.Simple.Utils ( debug )
import Distribution.Verbosity    ( Verbosity )
import System.Directory          ( canonicalizePath, createDirectoryIfMissing
                                 , doesFileExist, copyFile )
import System.FilePath           ( (</>) )

import qualified Distribution.Dev.Flags as F ( GlobalFlag(Sandbox), getVerbosity )

import Paths_cabal_dev ( getDataFileName )

-- A sandbox directory that we may or may not know what kind of
-- package format it uses
data UnknownVersion
data KnownVersion

data Sandbox a where
    UnknownVersion :: FilePath -> Sandbox UnknownVersion
    KnownVersion :: FilePath -> PackageDbType -> Sandbox KnownVersion

data PackageDbType = GHC_6_8_Db FilePath | GHC_6_10_Db | GHC_6_12_Db

-- NOTE: GHC < 6.12: compilation warnings about non-exhaustive pattern
-- matches are spurious (we'd get a type error if we tried to make
-- them complete!)
setVersion :: Sandbox UnknownVersion -> PackageDbType -> Sandbox KnownVersion
setVersion (UnknownVersion p) ty = KnownVersion p ty

getVersion :: Sandbox KnownVersion -> PackageDbType
getVersion (KnownVersion _ db) = db

sandbox :: Sandbox a -> FilePath
sandbox (UnknownVersion p) = p
sandbox (KnownVersion p _) = p

sPath :: FilePath -> Sandbox a -> FilePath
sPath p s = sandbox s </> p

localRepoPath :: Sandbox a -> FilePath
localRepoPath = sPath "packages"

pkgConf :: Sandbox KnownVersion -> FilePath
pkgConf s@(KnownVersion _ ty) = sPath (packageDbName ty) s
    where
      packageDbName (GHC_6_8_Db _) = "packages-6.8.conf"
      packageDbName GHC_6_10_Db = "packages-6.10.conf"
      packageDbName GHC_6_12_Db = "packages.conf.d"

cabalConf :: Sandbox a -> FilePath
cabalConf = sPath "cabal.config"

defaultSandbox :: FilePath
defaultSandbox = "./cabal-dev"

getSandbox :: [F.GlobalFlag] -> Maybe FilePath
getSandbox flgs = listToMaybe [ fn | F.Sandbox fn <- flgs ]

newSandbox :: Verbosity -> FilePath -> IO (Sandbox UnknownVersion)
newSandbox v relSandboxDir = do
  sandboxDir <- canonicalizePath relSandboxDir
  debug v $ "Using " ++ sandboxDir ++ " as the cabal-dev sandbox"
  createDirectoryIfMissing True sandboxDir
  let sb = UnknownVersion sandboxDir
  createDirectoryIfMissing True $ localRepoPath sb
  extant <- doesFileExist (indexTar sb)
  unless extant $ do
    emptyIdxFile <- getDataFileName $ "admin" </> indexTarBase
    copyFile emptyIdxFile (indexTar sb)
  return sb

resolveSandbox :: [F.GlobalFlag] -> IO (Sandbox UnknownVersion)
resolveSandbox flgs = do
  let v = F.getVerbosity flgs
  relSandbox <-
      case getSandbox flgs of
        Nothing -> do
          debug v $ "No sandbox specified. Using " ++ defaultSandbox
          return defaultSandbox
        Just s -> return $ s

  newSandbox v relSandbox

-- |The name of the cabal-install package index
indexTarBase :: FilePath
indexTarBase = "00-index.tar"

indexTar :: Sandbox a -> FilePath
indexTar sb = localRepoPath sb </> indexTarBase
