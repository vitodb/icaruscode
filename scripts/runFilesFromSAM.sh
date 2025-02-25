#!/usr/bin/env bash
#
# Creates file lists from a run number, or SAM definition, or just SAM files.
#
# Run with `--help` for usage instructions
#
# Author: Gianluca Petrillo (petrillo@slac.fnal.gov)
# Date:   March 2021
#
# Changes:
# 20210411 (petrillo@slac.fnal.gov) [1.0]
#   first public version
#
#

SCRIPTNAME="$(basename "$0")"
SCRIPTVERSION="1.0"

declare -r RawType='raw'
declare -r DecodeType='decoded'
declare -r XRootDschema='root'
declare -r dCacheLocation='dcache'
declare -r TapeLocation='enstore'

declare -r DefaultType="$DecodeType"
declare -r DefaultSchema="$XRootDschema"
declare -r DefaultLocation="$dCacheLocation"
declare -r DefaultDecoderStageName="stage0" # used to be 'decoder' up to a certain time

declare -r DefaultOutputPattern="%TYPE%-run%RUN%%DASHSCHEMA%%DASHLOCATION%.filelist"

# ------------------------------------------------------------------------------
function isFlagSet() {
  local VarName="$1"
  [[ -n "${!VarName//0}" ]]
} # isFlagSet()

function isDebugging() {
  local -i Level="${1:-1}"
  [[ "$DEBUG" -ge "$Level" ]]
} # isDebugging()

function DBGN() {
  local -i Level="$1"
  shift
  isDebugging "$Level" && STDERR "DBG[${Level}]| $*" ; 
}
function DBG() { DBGN 1 "$*" ; }

function STDERR() { echo "$*" >&2 ; }

function WARN() { STDERR "WARNING: $*" ; }
function INFO() { isFlagSet DoQuiet || STDERR "$*" ; }

function FATAL() {
  local -i Code=$1
  shift
  STDERR "FATAL(${Code}): $*"
  exit $Code
} # FATAL()

function LASTFATAL() {
  local -i res=$?
  [[ $res == 0 ]] || FATAL "$res" "$@"
} # LASTFATAL()


function PrintHelp() {

  cat <<EOH
Queries SAM for all the files in a run and translates each file into a URL.

Usage:  ${SCRIPTNAME}  [options] Spec [Spec ...] > run.filelist

Each specification may be a run number, a SAM definition (preceded by \`@\`,
e.g. \`@icarus_run005300_raw\`) or a file name.
In all cases, run, definition or file, they must be known to SAM.

Options:
--type=<${RawType}|${DecodeType}|...>  [${DefaultType}]
--decode , --decoded , -D
--raw , -R
--stage=STAGE
    select the type of files to query (raw from DAQ, decoded...);
    if the stage is explicitly selected, it is used as constraint in SAM query
--schema=<${XRootDschema}|...>  [${DefaultSchema}]
--xrootd , --root , -X
    select the type of URL (XRootD, ...)
--location=<${dCacheLocation}|${TapeLocation}>  [${DefaultLocation}]
--tape , --enstore , -T
--disk , --dcache , -C
    select the storage type

--output=OUTPUTFILE
    use OUTPUTFILE for all output file lists
--outputdir=OUTPUTDIR
    prepend all output filelist paths with this directory
-O
    create a list per run, with the pattern specified by \`--outputpattern\`:
--outputpattern=PATTERN  [${DefaultOutputPattern}]
    use PATTERN for the standard output file list (see option \`-O\` above);
    the following tags in PATTERN are replaced: \`%RUN%\` by the run number;
    \`%SCHEMA%\` by the URL schema; \`%LOCATION%\` by the storage location;
    \`%TYPE%\` by the file content type; and all tags prepended by \`DASH\`
    (e.g. \`%DASHTYPE%\`) are replaced by a dash (\`-\`) and the value of the
    tag only if the content of that tag is not empty

--quiet , -q
    do not print non-fatal information on screen while running
--debug[=LEVEL]
    enable debugging printout (optionally with the specified verbosity LEVEL)
--version, -V
--help , -h , -?
    print this help message

EOH

} # PrintHelp()


function PrintVersion() {
  cat <<EOV

${SCRIPTNAME} version ${SCRIPTVERSION}

EOV
} # PrintVersion()


# ------------------------------------------------------------------------------
function AddPathToList() {
  
  local Path="$1"
  
  DBGN 2 "Adding: '${Path}'"
  if [[ -n "$OutputFile" ]]; then
    echo "$Path" >> "$OutputFile"
  else
    echo "$Path"
  fi
  
} # AddPathToList()


declare -a TempFiles
function DeclareTempFile() {
  local Run="$1"
  
  local TemplateName="${SCRIPTNAME%.sh}-run${Run}.tmp.XXXXXX"
  local TempFile
  TempFile="$(mktemp --tmpdir "$TemplateName")"
  LASTFATAL "Failed to create a temporary file (after '${TemplateName}') for run ${Run}."
  TempFiles+=( "$TempFile" )
  
  echo "$TempFile"
  
} # DeclareTempFile()

function Cleanup() {
  rm -f "${TempFiles[@]}"
} # Cleanup()


function isRunNumber() { [[ "$1" =~ ^[[:digit:]]+$ ]]; }
function isSAMdefName() { [[ "${1:0:1}" == '@' ]]; }
function isSAMfile() { [[ "${1: -5}" == '.root' ]]; }
function SpecType() {
  local Spec="$1"
  local -Ar Tests=(
    ['run']='isRunNumber'
    ['SAMdef']='isSAMdefName'
    ['SAMfile']='isSAMfile'
  )
  local Type
  for Type in "${!Tests[@]}" ; do
    "${Tests[$Type]}" "$Spec" || continue
    echo "$Type"
    return 0
  done
  return 1
} # SpecType()


function BuildOutputFilePath() {
  local Pattern="$1"
  local Run="$2"
  
  local OutputName="$Pattern"
  
  local -A Replacements
  local VarName VarValue
  for VarName in Run Type Schema Location ; do
    VarValue="${!VarName}"
    Replacements["${VarName^^}"]="$VarValue"
    Replacements["DASH${VarName^^}"]="${VarValue:+"-${VarValue}"}"
  done
  local TagName
  for TagName in "${!Replacements[@]}" ; do  
    OutputName="${OutputName//%${TagName}%/${Replacements["$TagName"]}}"
  done
  
  echo "${OutputDir:+"${OutputDir%/}/"}${OutputName}"
} # BuildOutputFilePath()


# ------------------------------------------------------------------------------
function RunSAM() {
  local -a Cmd=( 'samweb' "$@" )
  
  DBG "${Cmd[@]}"
  "${Cmd[@]}"
  
} # RunSAM()


# ------------------------------------------------------------------------------
declare -a Specs
declare -i UseDefaultOutputFile=0 DoQuiet=0
declare OutputFile
declare Type="$DefaultType"
declare Schema="$DefaultSchema"
declare Location="$DefaultLocation"
declare OutputPattern="$DefaultOutputPattern" # not an option yet
declare -i iParam
for (( iParam=1 ; iParam <= $# ; ++iParam )); do
  Param="${!iParam}"
  if [[ "${Param:0:1}" == '-' ]]; then
    case "$Param" in
      ( '--raw' | '-R' )                  Type="$RawType" ;;
      ( '--decoded' | '--decode' | '-D' ) Type="$DecodeType" ;;
      ( '--type='* )                      Type="${Param#--*=}" ;;
      ( '--stage='* )                     Type="${Param#--*=}" ;;
      
      ( '--schema='* | '--scheme='* )     Schema="${Param#--*=}" ;;
      ( '--xrootd' | '--XRootD' | '--root' | '--ROOT' | '-X' ) Schema="$XRootDschema" ;;
      
      ( '--loc='* | '--location='* )      Location="${Param#--*=}" ;;
      ( '--dcache' | '--dCache' | '-C' )  Location="$dCacheLocation" ;;
      ( '--tape' | '--enstore' | '-T' )   Location="$TapeLocation" ;;
      
      ( "--output="* )                    OutputFile="${Param#--*=}" ;;
      ( "--outputpattern="* )             OutputPattern="${Param#--*=}" ;;
      ( "--outputdir="* )                 OutputDir="${Param#--*=}" ;;
      ( "-O" )                            UseDefaultOutputFile=1 ;;
      
      ( '--debug' )                       DEBUG=1 ;;
      ( '--debug='* )                     DEBUG="${Param#--*=}" ;;
      ( '--quiet' | '-q' )                DoQuiet=1 ;;
      ( '--version' | '-V' )              DoVersion=1 ;;
      ( '--help' | '-h' | '-?' )          DoHelp=1 ;;
      
      ( * )
        PrintHelp
        echo
        FATAL 1 "Invalid option #${iParam} ('${Param}')."
        ;;
    esac
  else
    Specs+=( "$Param" )
    LASTFATAL "Parameter #${iParam} ('${Param}') is not a valid (run) number."
  fi
done

if isFlagSet UseDefaultOutputFile && [[ -n "$OutputFile" ]]; then
  FATAL 1 "Options \`-O\` and \`--outputfile\` (value: '${OutputFile}') are exclusive."
fi

if isFlagSet DoVersion ; then
  PrintVersion
  [[ "${ExitWithCode:-0}" -gt 0 ]] || ExitWithCode=0
fi

if isFlagSet DoHelp ; then
  PrintHelp
  [[ "${ExitWithCode:-0}" -gt 0 ]] || ExitWithCode=0
fi

[[ -n "$ExitWithCode" ]] && exit "$ExitWithCode"


trap Cleanup EXIT

declare Constraints=''
case "${Type,,}" in
  ( 'raw' )     Constraints+=" and data_tier=raw" ;;
  ( * )
    if [[ "${Type,,}" == 'decoded' ]]; then
      Stage="$DefaultDecoderStageName"
    else
      Stage="$Type"
    fi
    Constraints+=" and icarus_project.stage=${Stage}"
    ;;
#   echo "Type '${Type}' not supported!" >&2
#   exit 1
esac


declare -i nErrors=0

declare Spec
[[ -n "$OutputDir" ]] && mkdir -p "$OutputDir"
if [[ -n "$OutputFile" ]]; then
  [[ "${OutputFile:0:1}" == '/' ]] || OutputFile="${OutputDir%/}/${OutputFile}"
  rm -f "$OutputFile"
fi
for Spec in "${Specs[@]}" ; do

  declare FileList="$(DeclareTempFile "$Spec")"
  if isFlagSet UseDefaultOutputFile ; then
    OutputFile="$(BuildOutputFilePath "$OutputPattern" "$Spec")"
    rm -f "$OutputFile"
  fi
  
  unset Run SAMdefName
  case "$(SpecType "$Spec")" in
    ( 'run' )
      Run="$Spec"
      JobTag="Run ${Run}"
      declare Query="run_number=${Run}${Constraints}"
      RunSAM list-files "$Query" > "$FileList"
      LASTFATAL "getting run ${Run} file list (SAM query: '${Query}')."
      ;;
    ( 'SAMdef' )
      SAMdefName="${Spec:1}"
      JobTag="SAM definition ${SAMdefName}"
      RunSAM list-definition-files "$SAMdefName" > "$FileList"
      LASTFATAL "getting ${JobTag} file list."
      ;;
    ( 'SAMfile' )
      FileName="$Spec"
      JobTag="SAM-declared file '${FileName}'"
      echo "$FileName" > "$FileList"
      ;;
    ( * )
      ERROR "Unknown type for specification '${Spec}'."
      let ++nErrors
      ;;
  esac
  
  declare -i nFiles="$(wc -l "$FileList" | cut -d' ' -f1)"
  declare FileName
  declare -i iFile=0
  declare -a FileURL
  INFO "${JobTag}: ${nFiles} files${OutputFile:+" => '${OutputFile}'"}"
  while read FileName ; do
    INFO "[$((++iFile))/${nFiles}] '${FileName}'"
    FileURL=( $(RunSAM get-file-access-url ${Schema:+"--schema=${Schema}"} ${Location:+"--location=${Location}"} "$FileName") )
    LASTFATAL "getting file '${FileName}' location from SAM."
    [[ "${#FileURL[@]}" == 0 ]] && FATAL 2 "failed getting file '${FileName}' location from SAM."
    [[ "${#FileURL[@]}" -gt 1 ]] && WARN "File '${FileName}' matched ${#FileURL[@]} locations (only the first one included):$(printf -- "\n- '%s'" "${FileURL[@]}")"
    AddPathToList "${FileURL[0]}"
  done < "$FileList"
  
done

[[ $nErrors -gt 0 ]] && FATAL 1 "${nErrors} error(s) accumulated while processing."

exit 0
