{-# LANGUAGE BangPatterns #-}

import Types
import Rewrite
import Profiling
import GeneAlg
import qualified GeneAlg2 as G2
import Config
import Result
------
import GA
import qualified Data.BitVector as B
import Data.Bits
import Data.Int
import System.Environment
import System.IO
import System.Process
import System.Directory
import Text.Read
import Control.DeepSeq
import System.FilePath

import Debug.Trace
import System.Random (StdGen)
import Data.Maybe (isJust, fromJust)

reps :: Int64
reps = runs

cfgFile :: FilePath
cfgFile = "config.atb"

checkBaseProgram :: Double -> Double -> IO ()
checkBaseProgram baseTime baseMetric = if baseTime < 0
                                       then error $ "Base program ran longer than expected. " ++
                                                  "We suggest a larger time budget."
                                       else if baseMetric <= 0
                                            then error $ "Base measurement is negligible (0). " ++
                                                 "Autobahn cannot optimize."
                                            else putStr $ "Base measurement is: " ++ (show baseTime)

fitness :: Cfg -> Int64 -> [FilePath] -> [BangVec] -> IO (Time, Int)
fitness cfg reps files bangVecs = do
  -- Read original
    let absPaths = map (\x -> projectDir cfg ++ "/" ++ x) files
    !progs  <- sequence $ map readFile absPaths
  -- Rewrite from gene
    !progs' <- sequence $ map (uncurry editBangs) $ zip absPaths (map B.toBits bangVecs) 
    rnf progs `seq` sequence $ map (uncurry writeFile) $ zip absPaths progs'
  -- Benchmark new
    -- buildProj projDir
    !(_, newMetricStat) <- benchmark cfg reps
  -- Recover original
    !_ <- sequence $ map (uncurry writeFile) $ zip absPaths progs
    let n_ones = length . (filter (\x -> x)) . B.toBits $ head bangVecs
    return (newMetricStat, n_ones)

fitnessNBangs :: Cfg -> Int64 -> [FilePath] -> [BangVec] -> IO Int
fitnessNBangs cfg reps files bangVecs = do
  -- Read original
    let absPaths = map (\x -> projectDir cfg ++ "/" ++ x) files
    !progs  <- sequence $ map readFile absPaths
  -- Rewrite from gene
    !progs' <- sequence $ map (uncurry editBangs) $ zip absPaths (map B.toBits bangVecs) 
    rnf progs `seq` sequence $ map (uncurry writeFile) $ zip absPaths progs'
  -- Benchmark new
    -- buildProj projDir
    !(_, newMetricStat) <- benchmark cfg reps
  -- Recover original
    !_ <- sequence $ map (uncurry writeFile) $ zip absPaths progs
    let n_ones = length . (filter (\x -> x)) . B.toBits $ head bangVecs
    return (if newMetricStat < 0 then 1000 else n_ones)
    
main :: IO () 
main = do 
  hSetBuffering stdout LineBuffering
  args <- getArgs
  cfg <- if null args then gatherCfg else manufactureCfg args
  putStrLn "Setting up optimization process..."
  putStrLn "Starting optimization process..."
  gmain cfg
  putStrLn $ "Optimization finished, please inspect and select candidate changes "
   ++ "(found in AutobahnResults under project root)"
      where
          
          gatherCfg = do 
            putStrLn "Configure optimization..."
            cfgExist <- doesFileExist cfgFile
            cfg <- if cfgExist then readCfg cfgFile else cliCfg
            return cfg
          manufactureCfg args = do 
                                     [a, b, c, d] <- getArgs
                                     (baseTime, baseMetric) <- benchmark (Cfg {projectDir = a, timeBudget = 10000, fitnessMetric = RUNTIME, inputArgs = ""}) 1
                                     print (baseTime, baseMetric)
                                     return Cfg { projectDir = a
                                                , pop = (read b)
                                                , gen = (read c)
                                                , arch = (read d)
                                                , timeBudget = deriveFitnessTimeLimit baseTime
                                                , fitnessMetric = RUNTIME
                                                , coverage = ["Main.hs"]
                                                , fitnessRuns = 1
                                                , getBaseTime = baseTime
                                                , getBaseMetric = baseMetric
                                                , inputArgs = ""
                                                }
                                      

gmain :: Cfg -> IO ()
gmain autobahnCfg = do
    let projDir = projectDir autobahnCfg
        cfg = createGAConfig autobahnCfg
        files = coverage autobahnCfg
        fitnessReps = fitnessRuns autobahnCfg
        baseTime  = getBaseTime autobahnCfg
        baseMetric  = getBaseMetric autobahnCfg
    putStrLn $ "Optimizing " ++ projDir
    putStrLn $ ">>>>>>>>>>>>>>>START OPTIMIZATION>>>>>>>>>>>>>>>"
    putStrLn $ "pop: " ++ (show $ pop autobahnCfg)
    putStrLn $ "gens: " ++ (show $ gen autobahnCfg)
    putStrLn $ "arch: " ++ (show $ arch autobahnCfg)
    
    checkBaseProgram baseTime baseMetric
    print baseTime
    print baseMetric
    
    let absPaths = map (\x -> projDir ++ "/" ++ x) files
        fitnessTimeLimit = deriveFitnessTimeLimit baseTime

  -- Pool: bit vector representing original progam
    progs <- sequence $ map readFile absPaths
    bs <- sequence $ map readBangs absPaths
    let !vecPool = rnf progs `seq` map B.fromBits bs

  -- Do the evolution!
    let ev = evolve :: StdGen -> GAConfig -> [BangVec] -> (Time, FitnessRun) -> IO (Archive [BangVec] Score)
    es <- ev g cfg vecPool (baseMetric,
                                       fitness (autobahnCfg { getBaseTime = fitnessTimeLimit }) fitnessReps files)
    let e = snd $ head es :: [BangVec]
    progs' <- sequence $ map (uncurry editBangs) $ zip absPaths (map B.toBits e)



    let bestMetricPerc = fst $ fromJust $ fst $ head $ filter (\x -> isJust $ fst x) es

    print bestMetricPerc

    newEs <- G2.ev g cfg vecPool (bestMetricPerc * baseMetric,
                                   fitness (autobahnCfg { getBaseTime = fitnessTimeLimit }) fitnessReps files)
    let e2 = snd $ head newEs :: [BangVec]

  -- Write the original files back to disk
    sequence $ map (uncurry writeFile) $ zip absPaths progs

  -- Write result
    putStrLn $ "best entity (GA): " ++ (unlines $ (map (printBits . B.toBits) e))

    putStrLn $ "best entity (GA) - r2: " ++ (unlines $ (map (printBits . B.toBits) e2))
    
    let newPath = projDir ++ "/" ++ "autobahn-survivor"
    code <- system $ "mkdir -p " ++ newPath
    
    let survivorPaths = map (\x -> projDir ++ "/" ++ "autobahn-survivor/" ++ x) files

    let survivorDirs = map (takeDirectory) survivorPaths
    sequence $ map (\x -> system $ "mkdir -p " ++ x) survivorDirs
    sequence $ map (uncurry writeFile) $ zip survivorPaths progs'
    putStrLn ">>>>>>>>>>>>>>FINISH OPTIMIZATION>>>>>>>>>>>>>>>"

      -- Write result page
    let es' = filter (\x -> fst x /= Nothing) es
        bangs = (map snd es') :: [[BangVec]]
    newFps <- createResultDirForAll projDir absPaths bangs
    let f = map fst es'
        scores = map getScore f
    genResultPage projDir (map fst scores) newFps projDir Nothing cfg 0.0 1



    where
       getScore s = case s of
                        Nothing -> error "filter should have removed all Nothing"
                        Just n -> n

