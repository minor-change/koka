-----------------------------------------------------------------------------
-- Copyright 2012-2021, Microsoft Research, Daan Leijen.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the LICENSE file at the root of this distribution.
-----------------------------------------------------------------------------
{-
    Main module.
-}
-----------------------------------------------------------------------------
module Compiler.Options( -- * Command line options
                         getOptions, processOptions, Mode(..), Flags(..)
                       -- * Show standard messages
                       , showHelp, showEnv, showVersion, commandLineHelp, showIncludeInfo
                       -- * Utilities
                       , prettyEnvFromFlags
                       , colorSchemeFromFlags
                       , prettyIncludePath
                       , isValueFromFlags
                       , CC(..), BuildType(..), ccFlagsBuildFromFlags
                       , buildType, unquote
                       , outName, buildDir, buildVariant
                       , cpuArch, osName
                       , optionCompletions
                       ) where


import Data.Char              ( toUpper, isAlpha, isSpace )
import Data.List              ( intersperse )
import Control.Monad          ( when )
import qualified System.Info  ( os, arch )
import System.Environment     ( getArgs )
import System.Directory       ( doesFileExist, doesDirectoryExist, getHomeDirectory )
import Platform.GetOptions
import Platform.Config
import Lib.PPrint
import Lib.Printer
import Common.Failure         ( raiseIO, catchIO )
import Common.ColorScheme
import Common.File            
import Common.Syntax          ( Target (..), Host(..), Platform(..), BuildType(..), platform32, platform64, platformJS, platformCS )
import Compiler.Package
import Core.Core( dataInfoIsValue )
{--------------------------------------------------------------------------
  Convert flags to pretty environment
--------------------------------------------------------------------------}
import qualified Type.Pretty as TP

prettyEnvFromFlags :: Flags -> TP.Env
prettyEnvFromFlags flags
  = TP.defaultEnv{ TP.showKinds       = showKinds flags
                 , TP.expandSynonyms  = showSynonyms flags
                 , TP.colors          = colorSchemeFromFlags flags
                 , TP.htmlBases       = htmlBases flags
                 , TP.htmlCss         = htmlCss flags
                 , TP.htmlJs          = htmlJs flags
                 , TP.verbose         = verbose flags
                 , TP.coreShowTypes   = showCoreTypes flags
                 }


colorSchemeFromFlags :: Flags -> ColorScheme
colorSchemeFromFlags flags
  = colorScheme flags


prettyIncludePath :: Flags -> Doc
prettyIncludePath flags
  = let cscheme = colorScheme flags
        path    = includePath flags
    in align (if null path then color (colorSource cscheme) (text "<empty>")
               else cat (punctuate comma (map (\p -> color (colorSource cscheme) (text p)) path)))

{--------------------------------------------------------------------------
  Options
--------------------------------------------------------------------------}
data Mode
  = ModeHelp
  | ModeVersion
  | ModeCompiler    { files :: [FilePath] }
  | ModeInteractive { files :: [FilePath] }

data Option
  = Interactive
  | Version
  | Help
  | Flag (Flags -> Flags)
  | Error String

data Flags
  = Flags{ warnShadow       :: Bool
         , showKinds        :: Bool
         , showKindSigs     :: Bool
         , showSynonyms     :: Bool
         , showCore         :: Bool
         , showFinalCore    :: Bool
         , showCoreTypes    :: Bool
         , showAsmCS        :: Bool
         , showAsmJS        :: Bool
         , showAsmC         :: Bool
         , showTypeSigs     :: Bool
         , showElapsed      :: Bool
         , evaluate         :: Bool
         , execOpts         :: String
         , library          :: Bool
         , target           :: Target
         , host             :: Host
         , platform         :: Platform
         , simplify         :: Int
         , simplifyMaxDup   :: Int
         , colorScheme      :: ColorScheme
         , outDir           :: FilePath      -- out
         , outTag           :: String
         , outBuildDir      :: FilePath      -- actual build output: <outdir>/<version>-<outtag>/<ccomp>-<variant>
         , includePath      :: [FilePath]    -- .kk/.kki files 
         , csc              :: FileName
         , node             :: FileName
         , cmake            :: FileName
         , cmakeArgs        :: String
         , ccompPath        :: FilePath
         , ccompCompileArgs :: Args
         , ccompIncludeDirs :: [FilePath]
         , ccompDefs        :: [(String,String)]
         , ccompLinkArgs    :: Args
         , ccompLinkSysLibs :: [String]      -- just core lib name
         , ccompLinkLibs    :: [FilePath]    -- full path to library
         , ccomp            :: CC
         , ccompLibDirs     :: [FilePath]    -- .a/.lib dirs
         , vcpkgRoot        :: FilePath
         , vcpkgTriplet     :: String
         , vcpkgAutoInstall :: Bool
         , vcpkg            :: FilePath
         , vcpkgLibDir      :: FilePath
         , vcpkgIncludeDir  :: FilePath
         , editor           :: String
         , redirectOutput   :: FileName
         , outHtml          :: Int
         , htmlBases        :: [(String,String)]
         , htmlCss          :: String
         , htmlJs           :: String
         , verbose          :: Int
         , exeName          :: String
         , showSpan         :: Bool
         , console          :: String
         , rebuild          :: Bool
         , genCore          :: Bool
         , coreCheck        :: Bool
         , enableMon        :: Bool
         , semiInsert       :: Bool
         , localBinDir      :: FilePath  -- directory of koka executable
         , localDir         :: FilePath  -- install prefix: /usr/local
         , localLibDir      :: FilePath  -- precompiled object files: <prefix>/lib/koka/v2.x.x  /<cc>-<config>/libkklib.a, /<cc>-<config>/std_core.kki, ...
         , localShareDir    :: FilePath  -- sources: <prefix>/share/koka/v2.x.x  /lib/std, /lib/samples, /kklib
         , packages         :: Packages
         , forceModule      :: FilePath
         , debug            :: Bool      -- emit debug info
         , optimize         :: Int       -- optimization level; 0 or less is off
         , optInlineMax     :: Int
         , optctail         :: Bool
         , optctailInline   :: Bool
         , parcReuse        :: Bool
         , parcSpecialize   :: Bool
         , parcReuseSpec    :: Bool
         , parcBorrowInference    :: Bool
         , asan             :: Bool
         , useStdAlloc      :: Bool -- don't use mimalloc for better asan and valgrind support
         , optSpecialize    :: Bool
         }

flagsNull :: Flags
flagsNull
  = Flags -- warnings
          True
          -- show
          False False  -- kinds kindsigs
          False False False False -- synonyms core fcore core-types
          False -- show asm
          False
          False
          False -- typesigs
          False -- show elapsed time
          True  -- executes
          ""    -- execution options
          False -- library
          C     -- target
          Node  -- js host
          platform64
          5     -- simplify passes
          10    -- simplify dup max (must be at least 10 to inline partial applications across binds)
          defaultColorScheme
          "out"    -- outdir 
          ""       -- outtag
          ("")     -- build dir
          []
          "csc"
          "node"
          "cmake"
          ""       -- cmake args
          
          ""       -- ccompPath
          []       -- ccomp args
          []       -- ccomp include dirs
          []       -- ccomp defs
          []       -- clink args
          []       -- clink sys libs
          []       -- clink full lib paths
          (ccGcc "gcc" 0 "gcc")
          (if onWindows then []        -- ccomp library dirs
                        else ["/usr/local/lib","/usr/lib","/lib"])
          
          ""       -- vcpkg root
          ""       -- vcpkg triplet
          True     -- vcpkg auto install
          ""       -- vcpkg
          ""       -- vcpkg libdir
          ""       -- vcpkg incdir

          ""       -- editor
          ""
          0        -- out html
          []
          ("styles/" ++ programName ++ ".css")
          ("")
          1        -- verbosity
          ""
          False
          "ansi"  -- console: ansi, html, raw
          False -- rebuild
          False -- genCore
          False -- coreCheck
          True  -- enableMonadic
          True  -- semi colon insertion
          ""    -- koka executable dir
          ""    -- prefix dir (default: <program-dir>/..)
          ""    -- localLib dir
          ""    -- localShare dir
          packagesEmpty -- packages
          "" -- forceModule
          True -- debug
          0    -- optimize
          12   -- inlineMax
          True -- optctail
          False -- optctailInline
          True -- parc reuse
          True -- parc specialize
          True -- parc reuse specialize
          False -- parc borrow inference
          False -- use asan
          False -- use stdalloc
          True  -- use specialization (only used if optimization level >= 1)

isHelp Help = True
isHelp _    = False

isVersion Version = True
isVersion _      = False

isInteractive Interactive = True
isInteractive _ = False

isValueFromFlags flags
 = dataInfoIsValue

{--------------------------------------------------------------------------
  Options and environment variables
--------------------------------------------------------------------------}
-- | The option table.
optionsAll :: [OptDescr Option]
optionsAll
 = let (xs,ys) = options in (xs++ys)

options :: ([OptDescr Option],[OptDescr Option])
options = (\(xss,yss) -> (concat xss, concat yss)) $ unzip
 [ option ['?','h'] ["help"]            (NoArg Help)                "show this information"
 , option []    ["version"]         (NoArg Version)                 "show the compiler version"
 , option ['p'] ["prompt"]          (NoArg Interactive)             "interactive mode"
 , flag   ['e'] ["execute"]         (\b f -> f{evaluate= b})        "compile and execute (default)"
 , flag   ['c'] ["compile"]         (\b f -> f{evaluate= not b})    "only compile, do not execute"
 , option ['i'] ["include"]         (OptArg includePathFlag "dirs") "add <dirs> to search path (empty resets)"
 , option ['o'] ["outdir"]          (ReqArg outDirFlag "dir")       "output files go under <dir> ('out' by default)"
 , option []    ["outname"]         (ReqArg exeNameFlag "name")     "base name of the final executable"
 , numOption 1 "n" ['v'] ["verbose"] (\i f -> f{verbose=i})         "verbosity 'n' (0=quiet, 1=default, 2=trace)"
 , flag   ['r'] ["rebuild"]         (\b f -> f{rebuild = b})        "rebuild all"
 , flag   ['l'] ["library"]         (\b f -> f{library=b, evaluate=if b then False else (evaluate f) }) "generate a library"
 , numOption 0 "n" ['O'] ["optimize"]   (\i f -> f{optimize=i})     "optimize (0=default, 1=space, 2=full, 3=aggressive)"
 , flag   ['g'] ["debug"]           (\b f -> f{debug=b})            "emit debug information (on by default)"
 , emptyline

 , config []    ["target"]          [("c",C),("js",JS),("cs",CS)] "" targetFlag  "generate C (default), javascript, or C#"
 , config []    ["host"]            [("node",Node),("browser",Browser)] "host" (\h f -> f{ target=JS, host=h}) "specify host for javascript: <node|browser>"
 , flag   []    ["html"]            (\b f -> f{outHtml = if b then 2 else 0}) "generate documentation"
 , option []    ["htmlbases"]       (ReqArg htmlBasesFlag "bases")  "set link prefixes for documentation"
 , option []    ["htmlcss"]         (ReqArg htmlCssFlag "link")     "set link to the css documentation style"
 , emptyline

 , flag   []    ["showtime"]       (\b f -> f{ showElapsed = b})    "show elapsed time and rss after evaluation"
 , flag   []    ["showspan"]       (\b f -> f{ showSpan = b})       "show ending row/column too on errors"
 , flag   []    ["showkindsigs"]   (\b f -> f{showKindSigs=b})      "show kind signatures of type definitions"
 , flag   []    ["showtypesigs"]   (\b f -> f{showTypeSigs=b})      "show type signatures of definitions"
 , flag   []    ["showsynonyms"]   (\b f -> f{showSynonyms=b})      "show expanded type synonyms in types"
 , flag   []    ["showcore"]       (\b f -> f{showCore=b})          "show core"
 , flag   []    ["showfcore"]      (\b f -> f{showFinalCore=b})     "show final core (with backend optimizations)"
 , flag   []    ["showcoretypes"]  (\b f -> f{showCoreTypes=b})     "show full types in core"
 , flag   []    ["showcs"]         (\b f -> f{showAsmCS=b})         "show generated c#"
 , flag   []    ["showjs"]         (\b f -> f{showAsmJS=b})         "show generated javascript"
 , flag   []    ["showc"]          (\b f -> f{showAsmC=b})          "show generated C"
 , flag   []    ["core"]           (\b f -> f{genCore=b})           "generate a core file"
 , flag   []    ["checkcore"]      (\b f -> f{coreCheck=b})         "check generated core" 
 , emptyline

 , option []    ["editor"]          (ReqArg editorFlag "cmd")       "use <cmd> as editor"
 , option []    ["outtag"]          (ReqArg outTagFlag "tag")       "set output tag (e.g. 'bundle')"
 , option []    ["builddir"]        (ReqArg buildDirFlag "dir")     "build into <dir> (= <outdir>/<ver>-<tag>/<variant>)"
 , option []    ["libdir"]          (ReqArg libDirFlag "dir")       "object library <dir> (= <prefix>/lib/koka/<ver>)"
 , option []    ["sharedir"]        (ReqArg shareDirFlag "dir")     "source library <dir> (= <prefix>/share/koka/<ver>)"
 , option []    ["cc"]              (ReqArg ccFlag "cmd")           "use <cmd> as the C backend compiler "
 , option []    ["ccincdir"]        (OptArg ccIncDirs "dirs")       "search semi-colon separated <dirs> for headers"
 , option []    ["cclibdir"]        (OptArg ccLibDirs "dirs")       "search semi-colon separated <dirs> for libraries"
 , option []    ["cclib"]           (ReqArg ccLinkSysLibs "libs")   "link with semi-colon separated system <libs>"
 , option []    ["ccopts"]          (OptArg ccCompileArgs "opts")   "pass <opts> to C backend compiler "
 , option []    ["cclinkopts"]      (OptArg ccLinkArgs "opts")      "pass <opts> to C backend linker "
 , option []    ["cclibpath"]       (OptArg ccLinkLibs "lpath")     "link with semi-colon separated libraries <lpath>"
 , option []    ["vcpkg"]           (ReqArg ccVcpkgRoot "dir")      "vcpkg root directory"
 , option []    ["vcpkgtriplet"]    (ReqArg ccVcpkgTriplet "tt")    "vcpkg target triplet"
 , flag   []    ["vcpkgauto"]       (\b f -> f{vcpkgAutoInstall=b}) "automatically install required vcpkg packages"
 , option []    ["csc"]             (ReqArg cscFlag "cmd")          "use <cmd> as the csharp backend compiler "
 , option []    ["node"]            (ReqArg nodeFlag "cmd")         "use <cmd> to execute node"
 , option []    ["color"]           (ReqArg colorFlag "colors")     "set colors"
 , option []    ["redirect"]        (ReqArg redirectFlag "file")    "redirect output to <file>"
 , configstr [] ["console"]  ["ansi","html","raw"] "fmt" (\s f -> f{ console = s }) "console output format: <ansi|html|raw>"

 -- hidden
 , hide $ fflag        ["asan"]      (\b f -> f{asan=b})             "compile with address, undefined, and leak sanitizer"
 , hide $ fflag        ["stdalloc"]  (\b f -> f{useStdAlloc=b})      "use the standard libc allocator"
 , hide $ fnum 3 "n"  ["simplify"]  (\i f -> f{simplify=i})          "enable 'n' core simplification passes"
 , hide $ fnum 10 "n" ["maxdup"]    (\i f -> f{simplifyMaxDup=i})    "set 'n' as maximum code duplication threshold"
 , hide $ fnum 10 "n" ["inline"]    (\i f -> f{optInlineMax=i})      "set 'n' as maximum inline threshold (=10)"
 , hide $ fflag       ["monadic"]   (\b f -> f{enableMon=b})         "enable monadic translation"
 , hide $ flag []     ["semi"]      (\b f -> f{semiInsert=b})        "insert semicolons based on layout"
 , hide $ fflag       ["parcreuse"] (\b f -> f{parcReuse=b})         "enable in-place update analysis"
 , hide $ fflag       ["parcspec"]  (\b f -> f{parcSpecialize=b})    "enable drop specialization"
 , hide $ fflag       ["parcrspec"] (\b f -> f{parcReuseSpec=b})     "enable reuse specialization"
 , hide $ fflag       ["binference"]    (\b f -> f{parcBorrowInference=b})     "enable reuse inference (does not work cross-module!)"
 , hide $ fflag       ["optctail"]  (\b f -> f{optctail=b})          "enable con-tail optimization (TRMC)"
 , hide $ fflag       ["optctailinline"]  (\b f -> f{optctailInline=b})  "enable con-tail inlining (increases code size)"
 , hide $ fflag       ["specialize"]  (\b f -> f{optSpecialize=b})      "enable inline specialization"

 -- deprecated
 , hide $ option []    ["cmake"]           (ReqArg cmakeFlag "cmd")        "use <cmd> to invoke cmake"
 , hide $ option []    ["cmakeopts"]       (ReqArg cmakeArgsFlag "opts")   "pass <opts> to cmake"

 ]
 where
  emptyline
    = flag [] [] (\b f -> f) ""

  option short long f desc
    = ([Option short long f desc],[])

  flag short long f desc
    = ([Option short long (NoArg (Flag (f True))) desc]
      ,[Option [] (map ("no-" ++) long) (NoArg (Flag (f False))) ""])

  numOption def optarg short long f desc
    = ([Option short long (OptArg (\mbs -> Flag (numOptionX def f mbs)) optarg) desc]
      ,[Option [] (map ("no-" ++) long) (NoArg (Flag (f (-1)))) ""])

  -- feature flags
  fflag long f desc
    = ([Option [] (map ("f"++) long) (NoArg (Flag (f True))) desc]
      ,[Option [] (map ("fno-" ++) long) (NoArg (Flag (f False))) ""])

  fnum def optarg long f desc
    = ([Option [] (map ("f"++) long) (OptArg (\mbs -> Flag (numOptionX def f mbs)) optarg) desc]
      ,[Option [] (map ("fno-" ++) long) (NoArg (Flag (f (-1)))) ""])

  hide (vis,hidden)
    = ([],vis ++ hidden)

  numOptionX def f mbs
    = case mbs of
        Nothing -> f def
        Just s  -> case reads s of
                     ((i,""):_) -> f i
                     _ -> f def  -- parse error

  config short long opts argDesc f desc
    = option short long (ReqArg validate valid) desc
    where
      valid = if null argDesc then "(" ++ concat (intersperse "|" (map fst opts)) ++ ")"
                              else argDesc
      validate s
        = case lookup s opts of
            Just x -> Flag (\flags -> f x flags)
            Nothing -> Error ("invalid value for --" ++ head long ++ " option, expecting any of " ++ valid)

  configstr short long opts argDesc f desc
    = config short long (map (\s -> (s,s)) opts) argDesc f desc

  targetFlag t f
    = f{ target=t, platform=case t of
                              JS -> platformJS
                              CS -> platformCS
                              _  -> platform64  }

  colorFlag s
    = Flag (\f -> f{ colorScheme = readColorFlags s (colorScheme f) })

  htmlBasesFlag s
    = Flag (\f -> f{ htmlBases = (htmlBases f) ++ readHtmlBases s })

  htmlCssFlag s
    = Flag (\f -> f{ htmlCss = s })

  includePathFlag mbs
    = Flag (\f -> f{ includePath = case mbs of
                                     Just s | not (null s) -> includePath f ++ undelimPaths s
                                     _ -> [] })

  outDirFlag s
    = Flag (\f -> f{ outDir = s })

  outTagFlag s
    = Flag (\f -> f{ outTag = s })    

  buildDirFlag s
    = Flag (\f -> f{ outBuildDir = s })

  libDirFlag s
    = Flag (\f -> f{ localLibDir = s })

  shareDirFlag s
    = Flag (\f -> f{ localShareDir = s })

  exeNameFlag s
    = Flag (\f -> f{ exeName = s })

  ccFlag s
    = Flag (\f -> f{ ccompPath = s })

  extendArgs prev mbs 
    = case mbs of Just s | not (null s) -> prev ++ unquote s
                  _      -> []
  
  ccCompileArgs mbs
    = Flag (\f -> f{ ccompCompileArgs = extendArgs (ccompCompileArgs f) mbs })

  ccIncDirs mbs
    = Flag (\f -> f{ ccompIncludeDirs = case mbs of
                                          Just s | not (null s) -> ccompIncludeDirs f ++ undelimPaths s
                                          _ -> [] })
  ccLibDirs mbs
    = Flag (\f -> f{ ccompLibDirs = case mbs of
                                          Just s | not (null s) -> ccompLibDirs f ++ undelimPaths s
                                          _ -> [] })


  ccLinkArgs mbs
    = Flag (\f -> f{ ccompLinkArgs = extendArgs (ccompLinkArgs f) mbs })

  ccLinkSysLibs s
    = Flag (\f -> f{ ccompLinkSysLibs = ccompLinkSysLibs f ++ undelimPaths s })
  ccLinkLibs mbs
    = Flag (\f -> f{ ccompLinkLibs = case mbs of
                                      Just s | not (null s) -> ccompLinkLibs f ++ undelimPaths s
                                      _ -> [] })
  ccVcpkgRoot dir
    = Flag (\f -> f{vcpkgRoot = dir })

  ccVcpkgTriplet triplet
    = Flag (\f -> f{vcpkgTriplet = triplet })

  cscFlag s
    = Flag (\f -> f{ csc = s })

  nodeFlag s
    = Flag (\f -> f{ node = s })

  editorFlag s
    = Flag (\f -> f{ editor = s })

  redirectFlag s
    = Flag (\f -> f{ redirectOutput = s })

  cmakeFlag s
      = Flag (\f -> f{ cmake = s })

  cmakeArgsFlag s
      = Flag (\f -> f{ cmakeArgs = s })

  
readHtmlBases :: String -> [(String,String)]
readHtmlBases s
  = map toBase (splitComma s)
  where
    splitComma :: String -> [String]
    splitComma xs
      = let (pre,ys) = span (/=',') xs
        in case ys of
             (_:post) -> pre : splitComma post
             []       -> [pre]

    toBase xs
      = let (pre,ys) = span (/='=') xs
        in case ys of
             (_:post) -> (pre,post)
             _        -> ("",xs)

-- | Environment table
environment :: [ (String, String, (String -> [String]), String) ]
environment
  = [ -- ("koka_dir",     "dir",     dirEnv,       "The install directory")
      ("koka_options", "options", flagsEnv,     "Add <options> to the command line")
    , ("koka_editor",  "command", editorEnv,    "Use <cmd> as the editor (substitutes %l, %c, and %f)")
    , ("koka_vcpkg",   "dir",     vcpkgEnv,     "vcpkg root directory")
    ]
  where
    flagsEnv s      = [s]
    editorEnv s     = ["--editor=" ++ s]
    vcpkgEnv dir    = ["--vcpkg=" ++ dir]
    -- dirEnv s        = ["--install-dir=" ++ s]

optionCompletions :: [(String,String)]
optionCompletions 
  = concatMap complete (fst options)
  where
    complete :: OptDescr Option -> [(String,String)]
    complete (Option shorts longs arg help)
      = let lreq = case arg of ReqArg _ _ -> "="
                               _          -> ""
            sreq = case arg of ReqArg _ _ -> " "
                               _          -> ""
        in zip ((map (\c -> "-" ++ [c] ++ sreq) shorts) ++ (map (\s -> "--" ++ s ++ lreq) longs))
               (repeat help)
        

{--------------------------------------------------------------------------
  Process options
--------------------------------------------------------------------------}
getOptions :: String -> IO (Flags,Flags,Mode)
getOptions extra
  = do env  <- getEnvOptions
       args <- getArgs
       processOptions flagsNull (env ++ words extra ++ args)

processOptions :: Flags -> [String] -> IO (Flags,Flags,Mode)
processOptions flags0 opts
  = let (preOpts,postOpts) = span (/="--") opts
        flags1 = case postOpts of
                   [] -> flags0
                   (_:rest) -> flags0{ execOpts = concat (map (++" ") rest) }
        (options,files,errs0) = getOpt Permute optionsAll preOpts
        errs = errs0 ++ extractErrors options
    in if (null errs)
        then let flags = extractFlags flags1 options
                 mode = if (any isHelp options) then ModeHelp
                        else if (any isVersion options) then ModeVersion
                        else if (any isInteractive options) then ModeInteractive files
                        else if (null files) then ModeInteractive files
                                             else ModeCompiler files                 
             in do ed   <- if (null (editor flags))
                            then detectEditor 
                            else return (editor flags)
                   pkgs <- discoverPackages (outDir flags)

                   (localDir,localLibDir,localShareDir,localBinDir) 
                        <- getKokaDirs (localLibDir flags) (localShareDir flags)
                   
                   -- cc
                   ccmd <- if (ccompPath flags == "") then detectCC
                           else if (ccompPath flags == "mingw") then return "gcc"
                           else return (ccompPath flags)
                   (cc,asan) <- ccFromPath flags ccmd
                   ccCheckExist cc
                   let stdAlloc = if asan then True else useStdAlloc flags   -- asan implies useStdAlloc
                       cdefs    = ccompDefs flags 
                                   ++ if stdAlloc then [] else [("KK_MIMALLOC","")]
                                   ++ if (buildType flags > DebugFull) then [] else [("KK_DEBUG_FULL","")]

                   -- vcpkg
                   (vcpkgRoot,vcpkg) <- vcpkgFindRoot (vcpkgRoot flags)
                   let triplet          = if (not (null (vcpkgTriplet flags))) then vcpkgTriplet flags
                                            else tripletArch ++ 
                                                 (if onWindows 
                                                    then (if (ccName cc `startsWith` "mingw") 
                                                            then "-mingw-static"
                                                            else "-windows-static-md")
                                                    else ("-" ++ tripletOsName))
                       vcpkgInstalled   = (vcpkgRoot) ++ "/installed/" ++ triplet
                       vcpkgIncludeDir  = vcpkgInstalled ++ "/include"
                       vcpkgLibDir      = vcpkgInstalled ++ (if buildType flags <= Debug then "/debug/lib" else "/lib")
                       vcpkgLibDirs     = if (null vcpkg) then [] else [vcpkgLibDir]
                       vcpkgIncludeDirs = if (null vcpkg) then [] else [vcpkgIncludeDir] 
                   return (flags{ packages    = pkgs,
                                  localBinDir = localBinDir,
                                  localDir    = localDir,
                                  localLibDir = localLibDir,
                                  localShareDir = localShareDir,

                                  optSpecialize  = if (optimize flags <= 0) then False 
                                                    else (optSpecialize flags),
                                  optInlineMax   = if (optimize flags < 0) 
                                                     then 0
                                                     else if (optimize flags <= 1) 
                                                       then (optInlineMax flags) `div` 3 
                                                       else (optInlineMax flags),

                                  ccompPath   = ccmd,
                                  ccomp       = cc,
                                  ccompDefs   = cdefs,
                                  asan        = asan,
                                  useStdAlloc = stdAlloc,
                                  editor      = ed,
                                  includePath = (localShareDir ++ "/lib") : includePath flags,

                                  vcpkgRoot   = vcpkgRoot,
                                  vcpkg       = vcpkg,
                                  vcpkgTriplet= triplet,
                                  vcpkgIncludeDir  = vcpkgIncludeDir,
                                  vcpkgLibDir      = vcpkgLibDir,
                                  ccompLibDirs     = vcpkgLibDirs ++ ccompLibDirs flags,
                                  ccompIncludeDirs = vcpkgIncludeDirs ++ ccompIncludeDirs flags
                               }
                          ,flags,mode)
        else invokeError errs

getKokaDirs :: FilePath -> FilePath -> IO (FilePath,FilePath,FilePath,FilePath)
getKokaDirs libDir0 shareDir0
  = do bin        <- getProgramPath
       let binDir  = dirname bin
           rootDir = rootDirFrom binDir
       isRootRepo <- doesDirectoryExist (joinPath rootDir "kklib")
       libDir1    <- if (null libDir0) then getEnvVar "koka_lib_dir" else return libDir0
       shareDir1  <- if (null shareDir0) then getEnvVar "koka_share_dir" else return shareDir0
       let libDir   = if (not (null libDir1)) then libDir1
                      else if (isRootRepo) then joinPath rootDir "out"
                      else joinPath rootDir ("lib/koka/v" ++ version)
           shareDir = if (not (null shareDir1)) then shareDir1           
                      else if (isRootRepo) then rootDir
                      else joinPath rootDir ("share/koka/v" ++ version)
       return (normalizeWith '/' rootDir,
               normalizeWith '/' libDir,
               normalizeWith '/' shareDir,
               normalizeWith '/' binDir)

rootDirFrom :: FilePath -> FilePath
rootDirFrom binDir
 = case span (/="dist-newstyle") (reverse (splitPath binDir)) of
     -- cabal
     (_, _:es) -> joinPaths (reverse es)
     -- other
     (rs,[]) -> case rs of
                  -- stack build
                  ("bin":_:"install":".stack-work":es)     -> joinPaths (reverse es)
                  ("bin":_:_:"install":".stack-work":es)   -> joinPaths (reverse es)
                  ("bin":_:_:_:"install":".stack-work":es) -> joinPaths (reverse es)
                  -- regular install
                  ("bin":es)   -> joinPaths (reverse es)
                  -- minbuild / jake build
                  (_:"out":es) -> joinPaths (reverse es)
                  _            -> binDir


extractFlags :: Flags -> [Option] -> Flags
extractFlags flagsInit options
  = let flags = foldl extract flagsInit options
    in flags
  where
    extract flags (Flag f)  = f flags
    extract flags _         = flags

extractErrors :: [Option] -> [String]
extractErrors options
  = concatMap extract options
  where
    extract (Error s) = [s ++ "\n"]
    extract _         = []

getEnvOptions :: IO [String]
getEnvOptions
  = do csc <- getEnvCsc
       xss <- mapM getEnvOption environment
       return (concat (csc:xss))
  where
    getEnvOption (envName,_,extract,_)
      = do s <- getEnvVar envName
           if null s
            then return []
            else return (extract s)

    getEnvCsc
      = do fw <- getEnvVar "FRAMEWORK"
           fv <- getEnvVar "FRAMEWORKVERSION"
           if (null fw || null fv)
            then do mbsroot <- getEnvVar "SYSTEMROOT"
                    let sroot = if null mbsroot then "c:\\windows" else mbsroot
                        froot = joinPath sroot "Microsoft.NET\\Framework"
                    mbcsc <- searchPaths [joinPath froot "v4.0.30319"
                                         ,joinPath froot "v3.5"
                                         ,joinPath froot "v3.0"
                                         ,joinPath froot "v2.0.50727"
                                         ,joinPath froot "v1.1.4322"]
                                         [exeExtension] "csc"
                    case mbcsc of
                      Nothing  -> return []
                      Just csc -> return ["--csc=" ++ csc ]
            else return ["--csc="++ joinPaths [fw,fv,"csc"]]


vcpkgFindRoot :: FilePath -> IO (FilePath,FilePath)
vcpkgFindRoot root
  = if (null root) 
      then do eroot   <- getEnvVar "VCPKG_ROOT"
              if (not (null eroot))
                then return (eroot, joinPath eroot vcpkgExe)
                else do homeDir <- getHomeDirectory
                        paths   <- getEnvPaths "PATH"
                        mbFile  <- searchPaths (paths ++ [joinPaths [homeDir,"vcpkg"]]) [] vcpkgExe
                        case mbFile of
                          Nothing     -> return ("", vcpkgExe)
                          Just fname0 -> do fname <- realPath fname0
                                            let root = case (reverse (splitPath (dirname fname))) of
                                                         ("bin":dirs) -> joinPaths (reverse ("libexec":dirs)) 
                                                         _ -> dirname fname
                                            return (root, fname)
      else return (root, joinPath root vcpkgExe)
  where 
    vcpkgExe = "vcpkg" ++ exeExtension

{--------------------------------------------------------------------------
  Detect C compiler
--------------------------------------------------------------------------}

type Args = [String]

data CC = CC{  ccName       :: String,
               ccPath       :: FilePath,
               ccFlags      :: Args,
               ccFlagsBuild :: [(BuildType,Args)],
               ccFlagsWarn  :: Args,
               ccFlagsCompile :: Args,
               ccFlagsLink    :: Args,
               ccAddLibraryDir :: FilePath -> Args,
               ccIncludeDir :: FilePath -> Args,
               ccTargetObj  :: FilePath -> Args,
               ccTargetExe  :: FilePath -> Args,
               ccAddSysLib  :: String -> Args,
               ccAddLib     :: FilePath -> Args,
               ccAddDef     :: (String,String) -> Args,
               ccLibFile    :: String -> FilePath,  -- make lib file name
               ccObjFile    :: String -> FilePath   -- make object file namen
            }


outName :: Flags -> FilePath -> FilePath
outName flags s
  = joinPath (buildDir flags) s

buildDir :: Flags -> FilePath    -- usually <outDir>/windows-x64-v2.x.x/<config>
buildDir flags
  = if (null (outBuildDir flags))
     then joinPaths [outDir flags, outVersionTag flags, buildVariant flags]
     else outBuildDir flags

outVersionTag :: Flags -> String   
outVersionTag flags
  = "v" ++ version ++ (if (null (outTag flags)) then "" else "-" ++ outTag flags)

buildVariant :: Flags -> String   -- for example: clang-debug, js-release
buildVariant flags
  = let pre  = if (target flags == C)
                 then ccName (ccomp flags)
                 else (show (target flags))
    in pre ++ "-" ++ show (buildType flags)


buildType :: Flags -> BuildType
buildType flags
  = if optimize flags < 0
      then DebugFull
      else if (optimize flags == 0)
        then Debug
        else if debug flags
               then RelWithDebInfo
               else Release

ccFlagsBuildFromFlags :: CC -> Flags -> Args
ccFlagsBuildFromFlags cc flags
  = case lookup (buildType flags) (ccFlagsBuild cc) of
      Just s -> s
      Nothing -> []

gnuWarn = words "-Wall -Wextra -Wno-unknown-pragmas -Wno-unused-parameter -Wno-unused-variable -Wno-unused-value" ++
          words "-Wno-missing-field-initializers -Wpointer-arith -Wshadow -Wstrict-aliasing"

ccGcc,ccMsvc :: String -> Int -> FilePath -> CC
ccGcc name opt path
  = CC name path []
        [(DebugFull,     words "-g -O0 -fno-omit-frame-pointer"),
         (Debug,         words "-g -O1"),
         (RelWithDebInfo,[if (opt == 1) then "-Os" else "-O2", "-g", "-DNDEBUG"]),
         (Release,       [if (opt > 2) then "-O3" else "-O2", "-DNDEBUG"])
        ]
        (gnuWarn ++ ["-Wno-unused-but-set-variable"])
        (["-c"]) -- ++ (if onWindows then [] else ["-D_GNU_SOURCE"]))
        []
        (\libdir -> ["-L",libdir])
        (\idir -> ["-I",idir])
        (\fname -> ["-o", (notext fname) ++ objExtension])
        (\out -> ["-o",out])
        (\syslib -> ["-l" ++ syslib])
        (\lib -> [lib])
        (\(def,val) -> ["-D" ++ def ++ (if null val then "" else "=" ++ val)])
        (\lib -> libPrefix ++ lib ++ libExtension)
        (\obj -> obj ++ objExtension)

ccMsvc name opt path
  = CC name path ["-DWIN32","-nologo"] 
         [(DebugFull,words "-MDd -Zi -Od -RTC1"),
          (Debug,words "-MDd -Zi -O1"),
          (Release,words "-MD -O2 -Ob2 -DNDEBUG"),
          (RelWithDebInfo,words "-MD -Zi -O2 -Ob2 -DNDEBUG")]
         ["-W3"]
         ["-EHs","-TP","-c"]   -- always compile as C++ on msvc (for atomics etc.)
         ["-link"]             -- , "/NODEFAULTLIB:msvcrt"]
         (\libdir -> ["/LIBPATH:" ++ libdir])
         (\idir -> ["-I",idir])
         (\fname -> ["-Fo" ++ ((notext fname) ++ objExtension)])
         (\out -> ["-Fe" ++ out ++ exeExtension])
         (\syslib -> [syslib ++ libExtension])
         (\lib -> [lib])
         (\(def,val) -> ["-D" ++ def ++ (if null val then "" else "=" ++ val)])
         (\lib -> libPrefix ++ lib ++ libExtension)
         (\obj -> obj ++ objExtension)         


ccFromPath :: Flags -> FilePath -> IO (CC,Bool {-asan-})
ccFromPath flags path
  = let name    = -- reverse $ dropWhile (not . isAlpha) $ reverse $
                  basename path
        gcc     = ccGcc name (optimize flags) path
        mingw   = gcc{ ccName = "mingw", ccLibFile = \lib -> "lib" ++ lib ++ ".a" }
        clang   = gcc{ ccFlagsWarn = gnuWarn ++ 
                                     words "-Wno-cast-qual -Wno-undef -Wno-reserved-id-macro -Wno-unused-macros -Wno-cast-align" }
        generic = gcc{ ccFlagsWarn = [] }
        msvc    = ccMsvc name (optimize flags) path
        clangcl = msvc{ ccFlagsWarn = ["-Wno-everything"] ++ ccFlagsWarn clang ++ 
                                      words "-Wno-extra-semi-stmt -Wno-extra-semi -Wno-float-equal",
                        ccFlagsLink = words "-Wno-unused-command-line-argument" ++ ccFlagsLink msvc,
                        ccFlagsCompile = ["-D__clang_msvc__"] ++ ccFlagsCompile msvc
                      }

        cc0     | (name `startsWith` "clang-cl") = clangcl
                | (name `startsWith` "mingw") = mingw
                | (name `startsWith` "clang") = clang
                | (name `startsWith` "gcc" || name `startsWith` "g++")   = if onWindows then mingw else gcc
                | (name `startsWith` "cl")    = msvc
                | (name `startsWith` "icc")   = gcc
                | (name == "cc") = generic
                | otherwise      = gcc

        cc = cc0{ ccFlagsCompile = ccFlagsCompile cc0 ++ ccompCompileArgs flags
                , ccFlagsLink    = ccFlagsLink cc0 ++ ccompLinkArgs flags }

    in if (asan flags)
         then if (not (ccName cc `startsWith` "clang" || ccName cc `startsWith` "gcc" || ccName cc `startsWith` "g++"))
                then do putStrLn "warning: can only use address sanitizer with clang or gcc (--fasan is ignored)"
                        return (cc,False)
                -- asan on Apple Silicon can't find leaks and throws an error
                -- We can't check for arch, since GHC 8.10 runs on Rosetta and detects x86_64
                else do let sanitize = if onMacOS then "-fsanitize=address,undefined" else "-fsanitize=address,undefined,leak"
                        return (cc{ ccName         = ccName cc ++ "-asan"
                                  , ccFlagsCompile = ccFlagsCompile cc ++ [sanitize,"-fno-omit-frame-pointer","-O0"]
                                  , ccFlagsLink    = ccFlagsLink cc ++ [sanitize] }
                               ,True)
       else if (useStdAlloc flags)
         then return (cc{ ccName = ccName cc ++ "-stdalloc" }, False)
         else return (cc,False)

ccCheckExist :: CC -> IO ()
ccCheckExist cc
  = do paths  <- getEnvPaths "PATH"
       mbPath <- searchPaths paths [exeExtension] (ccPath cc)
       case mbPath of
         Just _  -> return ()
         Nothing -> do putStrLn ("\nwarning: cannot find the C compiler: " ++ ccPath cc)
                       when (ccName cc == "cl") $
                         putStrLn ("   hint: run in an x64 Native Tools command prompt? or use the --cc=clang-cl flag?")
                       when (ccName cc == "clang-cl") $
                         putStrLn ("   hint: install clang for Windows from <https://llvm.org/builds/> ?")

-- unquote a shell argument string (as well as we can)
unquote :: String -> [String]
unquote s
 = filter (not . null) (scan "" s)
 where
   scan acc (c:cs) | c == '\"' || c == '\''     = reverse acc : scanq c "" cs
                   | c == '\\' && not (null cs) = scan (head cs:acc) (tail cs)
                   | isSpace c = reverse acc : scan "" (dropWhile isSpace cs)
                   | otherwise = scan (c:acc) cs
   scan acc []     = [reverse acc]

   scanq q acc (c:cs) | c == q    = reverse acc : scan "" cs
                      | c == '\\' && (not (null cs)) = scanq q (head cs:acc) (tail cs)
                      | otherwise = scanq q (c:acc) cs
   scanq q acc []     = [reverse acc]

onMacOS :: Bool
onMacOS
  = (dllExtension == ".dylib")

onWindows :: Bool
onWindows
  = (exeExtension == ".exe")

tripletOsName, osName :: String
tripletOsName
  = case System.Info.os of
      "linux-android" -> "android"
      "mingw32"       -> "mingw-static"
      "darwin"        -> "osx"
      os              -> os

osName
  = case System.Info.os of
      "mingw32"       -> "windows"
      "darwin"        -> "macos"
      "linux-android" -> "android"
      os              -> os

tripletArch :: String
tripletArch 
  = cpuArch

cpuArch :: String  
cpuArch
  = case System.Info.arch of 
      "aarch64"     -> "arm64"
      "x86_64"      -> "x64"
      "i386"        -> "x86"
      "powerpc"     -> "ppc"
      "powerpc64"   -> "ppc64"
      "powerpc64le" -> "ppc64le"
      arch          -> arch


detectCC :: IO String
detectCC
  = do paths <- getEnvPaths "PATH"
       (name,path) <- do envCC <- getEnvVar "CC"
                         findCC paths ((if (envCC=="") then [] else [envCC]) ++
                                       (if (onMacOS) then ["clang"] else []) ++
                                       (if (onWindows) then ["clang-cl","cl"] else []) ++
                                       ["gcc","clang","icc","cc","g++","clang++"])
       return path

findCC :: [FilePath] -> [FilePath] -> IO (String,FilePath)
findCC paths []
  = do -- putStrLn "warning: cannot find C compiler -- default to 'gcc'"
       return ("gcc","gcc")
findCC paths (name:rest)
  = do mbPath <- searchPaths paths [exeExtension] name
       case mbPath of
         Nothing   -> findCC paths rest
         Just path -> return (name,path)



detectEditor :: IO String
detectEditor
  = do paths <- getEnvPaths "PATH"
       findEditor paths [("code","--goto %f:%l:%c"),("atom","%f:%l:%c")]
       
findEditor :: [FilePath] -> [(String,String)] -> IO String
findEditor paths []
  = do -- putStrLn "warning: cannot find editor"
       return ""
findEditor paths ((name,options):rest)
  = do mbPath <- searchPaths paths [exeExtension] name
       case mbPath of
         Nothing -> findEditor paths rest
         Just _  -> return (name ++ " " ++ options)

{--------------------------------------------------------------------------
  Show options
--------------------------------------------------------------------------}
invokeError :: [String] -> IO a
invokeError errs
  = raiseIO (concat errs ++ " (" ++ helpMessage ++ ")\n")
  where
    helpMessage = "use \"--help\" for help on command line options"

-- | Show command line help
showHelp :: Printer p => Flags -> p -> IO ()
showHelp flags p
  = do doc <- commandLineHelp flags
       writePrettyLn p doc

-- | Show the morrow environment variables
showEnv :: Printer p => Flags -> p -> IO ()
showEnv flags p
  = do doc <- environmentInfo (colorSchemeFromFlags flags)
       writePrettyLn p (showIncludeInfo flags <-> doc)


commandLineHelp :: Flags -> IO Doc
commandLineHelp flags
  = do envInfo <- environmentInfo colors
       return $
          vcat
        [ infotext "usage:"
        , text "  " <.> text programName <+> text "<options> files"
        , empty
        , infotext "options:" <.> string (usageInfo "" (fst options))
        , infotext "remarks:"
        , text "  Boolean options can be negated, as in: --no-compile"
        , text "  The editor <cmd> can contain %f, %l, and %c to substitute the filename"
        , text "   line number and column number on the ':e' command in the interpreter."
        , text "  The html bases are comma separated <base>=<url> pairs where the base"
        , text "   is a prefix of module names. If using just a <url> it matches any module."
        , showIncludeInfo flags
        , envInfo
        , empty
        ]
  where
    colors
      = colorSchemeFromFlags flags

    infotext s
      = color (colorInterpreter colors) (text s)

showIncludeInfo flags
  = hang 2 (infotext "include path:" <-> prettyIncludePath flags) -- text (if null paths then "<empty>" else paths))
  where
    paths
      = concat $ intersperse [pathDelimiter] (includePath flags)

    colors
      = colorSchemeFromFlags flags

    infotext s
      = color (colorInterpreter colors) (text s)

environmentInfo colors
  = do vals <- mapM getEnvValue environment
       return (hang 2 (infotext "environment:" <->
                       vcat (map ppEnv vals) <-> text " "))
  where
    infotext s
      = color (colorInterpreter colors) (text s)

    ppEnv (name,val)
      = fill n (text name) <.> text "=" <+> val

    n = maximum [length name | (name,_,_,_) <- environment]

    getEnvValue (name,val,_,desc)
      = do s <- getEnvVar name
           if null s
            then return (name,text ("<" ++ val ++ ">"))
            else return (name,text s)


showVersion :: Printer p => Flags -> p -> IO ()
showVersion flags p
  = writePrettyLn p (versionMessage flags)

versionMessage :: Flags -> Doc
versionMessage flags
  =
  (vcat $ map text $
  [ capitalize programName ++ " " ++ version ++ ", " ++ buildTime ++
    (if null (compiler ++ compilerBuildVariant) then "" else " (" ++ compiler ++ " " ++ compilerBuildVariant ++ " version)")
  , ""
  ])
  <-> text "version:" <+> text version
  <-> text "bin    :" <+> text (localBinDir flags)
  <-> text "lib    :" <+> text (localLibDir flags)
  <-> text "share  :" <+> text (localShareDir flags)
  <-> text "build  :" <+> text (buildDir flags)
  <-> text "cc     :" <+> text (ccPath (ccomp flags))
  <->
  (color Gray $ vcat $ map text
  [ "Copyright 2012-2021, Microsoft Research, Daan Leijen."
  , "This program is free software; see the source for copying conditions."
  , "This program is distributed in the hope that it will be useful,"
  , "but without any warranty; without even the implied warranty"
  , "of merchantability or fitness for a particular purpose."
  ])
  where
    capitalize ""     = ""
    capitalize (c:cs) = toUpper c : cs
