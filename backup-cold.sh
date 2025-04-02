#!/usr/bin/env bash

# Declare variables
declare -A _backupListDictionary
_scriptDirectory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
_diskLabel=
_timestampOfBackup=$(date +%s)
_backupListFile=
_logFilePath="${_scriptDirectory}/${_timestampOfBackup}.log"
_coresLimit=$(($(grep -c ^processor /proc/cpuinfo)-1))
_backupHookAbortFile="${_scriptDirectory}/backup-hook-abort.sh"
_backupHookStartFile="${_scriptDirectory}/backup-hook-start.sh"
_backupHookFinishFile="${_scriptDirectory}/backup-hook-finish.sh"

# Include external configuration
test -f "${_scriptDirectory}/backup-cold.cfg" && source "${_scriptDirectory}/backup-cold.cfg"

# Useful functions
__info() { __log 'INFO' $1; }
__debug() { __log 'DEBUG' $1; }
__warn() { __log 'WARN' $1; }
__notice() { __log 'NOTICE' $1; }
__error() { __log 'ERROR' $1; }
__log() {
     local level=${1?}
     shift
     local line="[$(date '+%F %T')] $level: $*"
     echo "$line"
}

__usage() {
cat << EOF
usage: $0 options

OPTIONS:
   -h      Show this message
   -b      Path to inventory file containing backup targets. Default: None. Mandatory.
   -d      LABEL of disk used for cold backups. Default: None. Mandatory.
   -l      Path to log file. Default: ${_scriptDirectory}/<unix_timestamp>.log
EOF
}

abort_action() {
    __error "Received interrupt, exiting..."
    if [[ -f "${_backupHookAbortFile}" ]] && [[ -x "${_backupHookAbortFile}" ]]; then
        __info "Hook file ${_backupHookAbortFile} exists and has executable flag, executing" | tee -a "${_logFilePath}"
        ( "${_backupHookAbortFile}" "${_backupListDictionary[${archive_name}]}" )
    fi
    exit $?
}

# Register interruption signals 
trap abort_action INT SIGHUP SIGINT SIGTERM

for _executable in curl grep mkdir tee zstd xz date dirname readlink findmnt hostname; do
    if [ ! -f "$(command -v ${_executable})" -o ! -x "$(command -v ${_executable})" ]; then
        __error "${_executable} util is unavailable"
        exit 1
    fi
done

while getopts “hb:d:l:” OPTION
do
    case $OPTION in
        h)
            __usage
            exit 1
            ;;
        b)
            _backupListFile=$OPTARG
            ;;
        d)
            _diskLabel=$OPTARG
            ;;
        l)
            _logFilePath=$OPTARG
            ;;
        ?)
            __usage
            exit
            ;;
    esac
done

if [[ -z "${_backupListFile}" ]] || [[ -z "${_diskLabel}" ]]; then
     __usage
     exit 1
fi

# Check prerequisites

if [[ ! -d $(dirname "${_logFilePath}") ]]; then
    __error "Directory $(dirname "${_logFilePath}") for the log file does not exist"
    exit 1
fi

if [[ ! -L "/dev/disk/by-label/${_diskLabel}" ]]; then
    __error "Disk with label ${_diskLabel} does not exist" | tee -a "${_logFilePath}"
    exit 1
fi

_realDevice=$(readlink -f /dev/disk/by-label/${_diskLabel} 2>/dev/null)
_mountRealDevicePath=$(findmnt -nrS "${_realDevice}" | awk '{print $1}')

if (( $(grep -c . <<<"${_mountRealDevicePath}") > 1 )); then
    __error "Multiple mount points have been found for the provided disk label: ${_diskLabel}"
    for mountPointPath in ${_mountRealDevicePath};
    do
        __error "Disk ${_realDevice} has mount point: ${mountPointPath}"
    done
    __error "Please provide the disk label with a sole mount point"
    exit 1
elif [[ ! -z "${_mountRealDevicePath}" ]]; then
    __info "Mount point for disk with label ${_diskLabel} (${_realDevice}) is ${_mountRealDevicePath}" | tee -a "${_logFilePath}"
else
    __error "Mount point for disk with label ${_diskLabel} has not been found" | tee -a "${_logFilePath}"
    exit 1
fi

if [[ ! -f "${_backupListFile}" ]]; then
    __error "File ${_backupListFile} with list of files and/or directories to backup has not been found" | tee -a "${_logFilePath}"
    exit 1
fi

# Read inventory file
__info "Validating content of backup list in file \"${_backupListFile}\"" | tee -a "${_logFilePath}"

while IFS='|' read -r archive_name backup_data; do
    if [[ "${archive_name}" =~ ^\# ]]; then
        __warn "Ignoring commented out: ${archive_name}" | tee -a "${_logFilePath}"
        continue
    fi

        if [[ -z "${archive_name}" || -z "${backup_data}" ]]; then
                __error "Backup list contains malformed data. Correct format: archive_filename|/path/to/element1::/path/to/element2" | tee -a "${_logFilePath}"
                exit 1
        fi

    data_array=( $(echo -n "${backup_data}" | sed 's/::/ /g') )

    for element in "${data_array[@]}"; do
        if [ ! -e "${element}" ]; then
            __error "Element ${element} does not exist on filesystem" | tee -a "${_logFilePath}"
            exit 1
        fi
    done

    _backupListDictionary[${archive_name}]="$(echo -n ${backup_data} | sed 's/::/ /g')"
done < "${_backupListFile}"

if [ "${#_backupListDictionary[@]}" -eq 0 ]; then
    __error "Backup targets not found" | tee -a "${_logFilePath}"
    exit 1
fi

__info "Output directory: ${_mountRealDevicePath}/$(hostname -f)/${_timestampOfBackup}"
mkdir -p "${_mountRealDevicePath}/$(hostname -f)/${_timestampOfBackup}"

# Start backup process
__info "Starting backup task" | tee -a "${_logFilePath}"

for archive_name in "${!_backupListDictionary[@]}"; do
    __info "Backup ${_backupListDictionary[${archive_name}]} to ${archive_name}" | tee -a "${_logFilePath}"

    if [[ -f "${_backupHookStartFile}" ]] && [[ -x "${_backupHookStartFile}" ]]; then
        __info "Hook file ${_backupHookStartFile} exists and has executable flag, executing" | tee -a "${_logFilePath}"
        ( "${_backupHookStartFile}" "${_backupListDictionary[${archive_name}]}")
    fi

    if [ "${COMPRESS_TYPE}" == "LZMA2" -o "${COMPRESS_TYPE}" == "LZMA2" ]; then
        __info "Compression type LZMA2 is used"
        tar vc -I"xz -T${_coresLimit} -9e" -f "${_mountRealDevicePath}/$(hostname -f)/${_timestampOfBackup}/${archive_name}.tar.xz" ${_backupListDictionary[${archive_name}]} | tee -a "${_logFilePath}"
    else
        __info "Compression type ZSTD is used"
        tar vc -I"zstd -T${_coresLimit} --ultra -22" -f "${_mountRealDevicePath}/$(hostname -f)/${_timestampOfBackup}/${archive_name}.tar.zst" ${_backupListDictionary[${archive_name}]} | tee -a "${_logFilePath}"
    fi

    if [[ -f "${_backupHookFinishFile}" ]] && [[ -x "${_backupHookFinishFile}" ]]; then
        __info "Hook file ${_backupHookFinishFile} exists and has executable flag, executing" | tee -a "${_logFilePath}"
        ( "${_backupHookFinishFile}" "${_backupListDictionary[${archive_name}]}" )
    fi
done

__info "Backup task has been finished successfully" | tee -a "${_logFilePath}"
