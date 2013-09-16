#!/bin/bash

#       -------------------------------------------------------------------
#
#       Shell program to back up a host, or list of hosts, via rsync.
#
#       Copyright 2008-2013, Chip Bacon <chip@infotactix.com>.
#							 Matt Kissel <matt.c.kissel@gmail.com>
#
#       This program is free software; you can redistribute it and/or
#       modify it under the terms of the GNU General Public License as
#       published by the Free Software Foundation; either version 2 of the
#       License, or (at your option) any later version.
#
#       This program is distributed in the hope that it will be useful, but
#       WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#       General Public License for more details.
#
#       Description:
#
#
#       NOTE: You must be the superuser to run this script.
#       WARNING!: May contain security info.  Do not set world-readable.
#
#       Dependencies: rsync, grep, sed, awk, , getopt (GNU) and coreutils
#                (http://www.gnu.org/software/coreutils/)
#
#       Usage:
#
#               snapbak [-f host_list_file] [-s host_name] [ -h | --help ]
#
#       Options:
#
#               -f  host list 		    Back up a list of hosts from file
#                                       (one host name or IP per line)
#
#               -s  host name or IP     Back up a single host
#
#               -h, --help              Display this help message and exit.
#
#--------------------------- POTENTIAL NEW OPTIONS ----------------------------
#
#               -f  temp directory      path of directory to place temp files
#                                       (they will only be placed in an
#                                       existing directory) defaults to /tmp
#
#               -s  back-up path        path of backup repository/directory
#
#               -h  num keepdays        the number of days to back up files
#                                       by default if not read-in
#                                       (currently 21)
#
#               -f  log directory       path of directory to put log files
#
#               -f  exclude file        path of file containing the list of
#                                       modules to exclude from this snapbak
#
#               --debug                 run snapbak in debug mode i.e.
#                                       more verbose, back-up and delete
#                                       aren't executed but intent is output
#                                       to STDOUT and log files
#
#               --fqdn  use fqdn        use fully qualified  domain name for
#                                       naming backup directories
#                                       
#
#       -------------------------------------------------------------------

#TODO USE PARAMETERS NOT LIKE AN IDIOT I.E. LOCAL VARIABLES
#=======================================================================
# <<<<<< Includes / Constants >>>>>>
#=======================================================================
PROGNAME=$(basename $0)
VERSION="0.1.0"
CONFIG_FILE="/opt/snapbak/snapbak.conf"


if [[ -r $CONFIG_FILE ]] ; then
    source $CONFIG_FILE
    else
        echo "ERROR include $CONFIG_FILE"
    #TODO ELSE ERROR EXIT?
fi

#DEBUG to remove all code for debugging to clean up code
# and output the result to file: "snapbak"          #DEBUG
#run the command:                                   #DEBUG
# grep -v "#DEBUG" snapbakdebug > snapbak
DEBUG=true #DEBUG
DEBUG_LOG_DIR="/var/log/snapbak/debug" #DEBUG
DEBUG_LOG="debug.log" #DEBUG




#TODO make temp file to store today's date so we can check
#if it's running twice in one day
#TODO or make it run twice in one day
#TODO make debug not produce logs

#=======================================================================
# <<<<<< Functions >>>>>>
#=======================================================================


#-----------------------------------------------------------------------
# Function to remove temporary files and other housekeeping
#        No arguments
#-----------------------------------------------------------------------
function clean_up
{
    if $DEBUG ; then echo "Cleaning up ...$temp_file" >> $DEBUG_LOG ; fi #DEBUG
    rm -f ${temp_file}
}


#-----------------------------------------------------------------------
# Function for exit due to fatal program error
#
#       Accepts 1 argument:
#           string containing descriptive error message
#-----------------------------------------------------------------------
function error_exit
{
    echo "${PROGNAME}: ${1:-"Unknown Error"}" >&2
    clean_up
    exit 1
}


#-----------------------------------------------------------------------
# Function called for a graceful exit
#-----------------------------------------------------------------------
function graceful_exit
{
    if $DEBUG ; then echo "Exiting..." ; fi #DEBUG
    clean_up
    exit
}


#-----------------------------------------------------------------------
# Function to handle termination signals
#       Arguments:
#           $1: signal_spec
#-----------------------------------------------------------------------
function signal_exit
{
    case $1 in
        INT)    echo "$PROGNAME: Program aborted by user" >&2
                clean_up
                exit
                ;;
        TERM)   echo "$PROGNAME: Program terminated" >&2
                clean_up
                exit
                ;;
        *)      error_exit "$PROGNAME: Terminating on unknown signal"
           ;;
    esac
}


#-----------------------------------------------------------------------
# Function to create temp file name
#
#       Arguments:
#           $1: host_name
#       Returns:
#           Echos out the name of the temp file
#-----------------------------------------------------------------------
function make_temp_file
{
  local temp_file=""
  
   # Use pre-defined tmp directory if it is set and exists
   # Otherwise use /tmp
   if [ -z "$TEMP_DIR" -o ! -d "$TEMP_DIR" ]; then
        TEMP_DIR=/tmp
   fi

   # Temp file for this script, using paranoid method of creation to
   # insure that file name is not predictable.  This is for security to
   # avoid "tmp race" attacks.  If more files are needed, create using
   # the same form.
   temp_file=$(mktemp -q "${TEMP_DIR}/${1}.modules.$$.XXXXXX")

   echo ${temp_file}
}


#-----------------------------------------------------------------------
# Function to display usage message (does not exit)
#-----------------------------------------------------------------------
function usage
{
    echo "Usage: ${PROGNAME} [-f <host list file>] [-s <host name or IP>] [-h | --help]"
}


#-----------------------------------------------------------------------
# Function to display help message for program
#-----------------------------------------------------------------------
function helptext
{ 
    local tab=$(echo -en "\t\t")
    
    cat <<EOF
    
    ${PROGNAME} ver. ${VERSION}
    This is a program to back up a host, or list of hosts, via rsync.
    
    $(usage)
    
    Options:
       -f  host list           Back up a list of hosts from file
                               (one host name or IP per line)
                               This overrides the LIST_OF_HOSTS
                               setting in ${PROGNAME}.
    
       -s  host name or IP     Back up a single host
    
       -h, --help              Display this help message and exit.
    
    
    NOTE: You must be the superuser to run this script.
EOF
} 


#-----------------------------------------------------------------------
# Function to check if user is root
#-----------------------------------------------------------------------
function root_check
{
    #instead of complex regex  we can use the much simpler
    #checks set-user-id flag on file   -u : limits id to just the uid
    if [ "$(id -u)" != "0" ]; then
        error_exit "You must be the superuser to run this script."
    fi
}


#-----------------------------------------------------------------------
# Function to check if host identifier is a valid IPv4 address
#
#       Arguments:
#           $1: host2chk
#       Returns:
#           ERR (0 is testable IP,  1, 3  mean testable hostnames)
#-----------------------------------------------------------------------
#ERROR CODE
#0-valid IP
#1-hostname w/ '.' (3 of them)
#2-treat as hostname (non 4 segment and not entirely numbers)
#3-empty segment '' invalid
#4-one seg is over 254 (invalid IP)
#5-entirely numbers so we can't ping it

function valid_IPv4()
{
    local host=$1
    ERR=0
    oldIFS=$IFS
    IFS=.
    set -f
    set -- $1
    
    # check to see if there are 4 segments when delimited by
    # a '.'  meaning it is likely an IP address

    #TODO 127.0 is an invalid IP and we treat it as a hostname
    #      if we ping it it says "Do you want to ping broadcast? Then -b"
    #       but this is only for local so not too big of a deal
    if [[ $# -eq 4  && $host =~ ^[.0-9]+$ ]]; then
      for seg
      do
        case $seg in      
            "")
                ERR=3
                echo "ERROR Host: $host has invalid segment: '' and is not a valid host" 1>&2
                break
                ;;
            *)
                if [[ $seg -gt 254 ]] ; then
                    ERR=4 #if segment is greater than 254 it's an invalid IP
                    echo "ERROR Host: $host has invalid segment over 254" 1>&2
                    break
                fi
                ;;
        esac
      done
    else
        if [[ $host =~ ^[0-9]+$ ]] ; then
            #if it's just numeric ping will have an error
            #so don't accept it ( ERR > 3 || ERR < 1 )
            ERR=5
            echo "ERROR Host: $host is all numbers and is not a valid host" 1>&2
        elif [[ $host =~ ^[^[:alnum:]] ]] ; then
            ERR=6
            echo "ERROR Host: $host starts with something non-alphanumeric and is not a valid host" 1>&2
        else
            #otherwise treat it as a hostname
            ERR=2
        fi
    fi
    IFS=$oldIFS
    set +f
    return $ERR
}


#-----------------------------------------------------------------------
# Function to check if host is up (responds to ping)
#
#       Arguments:
#           $1: host2chk
#      Returns:
#           number of packets received
#           i.e. 1 for a successful ping
#                0 for a failed ping
#-----------------------------------------------------------------------
function ping_test()
{
    #error message to dev/null or  are null strings checked before hand
    test=$(ping -q -c 1 -w 1 -n "$1" 2>&1 |\
        grep -i "^PING\|0\ received" |\
        awk '/67\.215\..*|0\ received|unknown\ host/')
    
    if [[ -z $test ]] ;then
        #received a packet
        return 0 #exit with success code
    else
        #no packets returned or DNS bounce back
        return 1 #exit with error code
    fi
    
}


#-----------------------------------------------------------------------
# Function to check if hostname is valid and host is up
#
#       Requires 2 functions:
#           valid_IPv4
#           ping_test
#       Arguments:
#           $1: host2chk
#       Returns:
#           Echos out a valid filename for the host
#               IP address with '_' instead of '.' or
#               Capitalized host name
#-----------------------------------------------------------------------
function check_host()
{
    local host2chk=$1
    local host_is_up
    
    valid_IPv4 ${host2chk}
    # Exit val of IPv4 check lets us know if it's a valid IP
    case $? in
        0)
            ## host name is an IP addy so ping it
            ping_test ${host2chk}
            host_is_up=$?
            
            #echo the host address out of the function
            #replacing '.' with '_' (e.g 127.0.0.1 -> 127_0_0_1)
            #so we can use it as a filename
            [[ $host_is_up == 0 ]] && echo ${host2chk}|tr '.' '_' 

            ;;
        1|2)
            # host name is not a valid IP, treat as a name and check it
            ping_test ${host2chk}
            host_is_up=$?
           
            if [[ $host_is_up == 0 ]] ; then
                if $FQDN ; then
                    #TODO don't know if we want uppercase here
                    tr -s '.' '_' <<< ${host2chk} |tr '[a-z]' '[A-Z]'
                    
                # use a delimiter to cut the host to just the host name
                # and return name in all caps
                # (e.g. gobstopper.candy.com -> GOBSTOPPER)
                else
                    cut -d "." -f1 <<< ${host2chk} |tr '[a-z]' '[A-Z]'
                fi
            fi
            ;;
    esac
}


#-----------------------------------------------------------------------
# Function to delete old directories that aren't neccessary
#  also checks parent directories to see if they're empty
#  and will delete if necessary
#
#       Arguments:
#           $1: Directory (path)
#           $2: max num times to recurse and check parent directories
#               (e.g. a val of 0 checks just the directory and
#                1  would check the directory and its parent)
#                because we normally check all of date/host/module 
#---------------------------------- -------------------------------------
function del_dir()
{
    dir=$1
    
    #default iterations of recursion is 2
    iter=${2:-2}
    
    #save the parent directory so we can check it if necessary 
    parent=$(dirname $dir)
    
    if $DEBUG ; then    #DEBUG
        echo "DEBUG: del_dir:  would delete $dir if not debugging" >> $DEBUG_LOG  #DEBUG
    else    #DEBUG
        #only delete if we're not debugging
        echo "Deleting $dir..." >> $log
        echo "Deleting $dir..."
        rm -rf $dir
    fi  #DEBUG
    
    #if we're supposed to recurse and the parent is empty
    if [[ $iter > 0 && -z "$(ls $parent)" ]] ; then
        del_dir $parent $((--iter))
    fi
}


#-----------------------------------------------------------------------
# Function to check age of directories and call delete function
#   if they are older than we should keep
#-----------------------------------------------------------------------
function chk_del_dir_list()
{
    deleting=false
    
    #if $DEBUG ; then echo -e "\n\nin chk_del with host: $host_label  mod: $mod_name keepdays" >> $DEBUG_LOG ; fi #DEBUG 
    
    #we can delete everything before this date
    del_date=$(date --date="$(($keepdays)) days ago" +%Y-%m-%d--%a)
    
    for dir in $dir_list
    do
        #dir_date=$(echo $dir_list | cut -d '/' -f2 | sort -rn)
        #if we've already reached an outdated file on a previous
        #iteration this one is even older, so delete it
        if $deleting ; then
            del_dir $BACKUP_REPOS/$host_label/$dir/$mod_name
        else     
            #if it's older than we want to keep, delete it
            if [[ $dir < $del_date ]]; then
                #if $DEBUG ; then echo "In /$host_label/$dir/$mod_name deleting everything older than $del_date" >> $DEBUG_LOG ; fi #DEBUG
                #since the directories are in chronological order
                #once we find an old one, we want to delete everything
                #after that, so set a boolean so we know we're at that point 
                deleting=true
                
                if $DEBUG ; then echo -e "\nFound first old dir: /$host_label/$dir/$mod_name... deleting anything older" >> $DEBUG_LOG  ; fi #DEBUG
                del_dir $BACKUP_REPOS/$host_label/$dir/$mod_name
            else    #DEBUG
                if $DEBUG ; then echo "/$host_label/$dir/$mod_name is young enough to stay" >> $DEBUG_LOG ; fi   #DEBUG
            fi
        fi
    done  
}




#-----------------------------------------------------------------------
# Function to sync all modules within a host
#
#       Arguments:
#           $1: host_label either the IP or name of the host
#           $2: a file with a list of the modules
#---------------------------------- -------------------------------------
function module_logic()
{
    local host_label="$1"
    local module_list="$2"
    local rsync_opt=""
    
    while read mod_line
    do
        #mod_line has two fields (1-the name 2-the num of days to keep the files)
        mod_name=$(echo ${mod_line}|cut -d " " -f1)
        if $DEBUG ; then echo -e "\n\n\n---------------- module_logic: module read-in line from $host_label is $mod_line --------------------" >> $DEBUG_LOG ;  fi  #DEBUG
             
            
        #make sure a "latest" backup directory exists to store today's data
        if ! $DEBUG ;then   #DEBUG
           if [[ ! -e $BACKUP_REPOS/$host_label/latest/$mod_name/ ]]; then
               mkdir -p $BACKUP_REPOS/$host_label/latest/$mod_name/
           fi
        fi  #DEBUG
        
        
##----------------------------------------BEGIN LOG----------------------------------
        #TODO possiblity of extracting log logic to separate function
        log="$LOG_DIR/$host_label.$mod_name.log"
        
        #check for directory for the log file if it doesn't exist, make it
        if [[ -d $LOG_DIR ]] ; then
            if $DEBUG ; then echo "LOG_DIR exists" >> $DEBUG_LOG ; fi  #DEBUG
            #Check to see if there's a log file for the previous backup
            if [[ -e $log && -f $log ]]; then
                #old log exists so move it to a temp spot while we make backup
                if ! $DEBUG ; then #DEBUG              
                    cp $log $BACKUP_REPOS #/usr2/
                fi  #DEBUG
            elif $DEBUG ; then echo "DEBUG: No old log file found" >> $DEBUG_LOG #DEBUG
            fi
        else
            mkdir $LOG_DIR
        fi
        
        ##begin the log for sync and backup
        echo "Begin log for $host_label.$mod_name" > $log
        echo "..." >> $log
        
        ##save the beginning time before running rsync
        start_time=$(date)
        
        #grab the most recent folder's directory size and save it (if it exists)
        if [[ -d $BACKUP_REPOS/$host_label/latest/$mod_name/ ]];then
                start_size=$(du -sm "$BACKUP_REPOS/$host_label/latest/$mod_name/" | cut -f1)
            else
                start_size=0
        fi
 
##-------------------------------------START RSYNC---------------------------------------
        rsync_opt=$(get_rsync_opts $host_label $mod_name)
        #sync files on host to the server   format: rsync [options] [src] [dest]
        #and save rsync log to the log file
        if $DEBUG ; then             #DEBUG
           echo " RSYNC COMMAND $RSYNC $rsync_opt rsync://$host/$mod_name $BACKUP_REPOS/$host_label/latest/$mod_name"  >> $DEBUG_LOG      #DEBUG
           $RSYNC $rsync_opt -v rsync://$host/$mod_name $BACKUP_REPOS/$host_label/latest/$mod_name >> $log    #DEBUG ADD -n back later
        else    #DEBUG
            $RSYNC $rsync_opt rsync://$host/$mod_name $BACKUP_REPOS/$host_label/latest/$mod_name >> $log
        fi  #DEBUG
       
       #chmod 755 $BACKUP_REPOS/$host_label/
       #chmod 755 $BACKUP_REPOS/$host_label/latest/
       #chmod 755 $BACKUP_REPOS/$host_label/latest/$mod_name
       #chmod 755 $BACKUP_REPOS/$YESTERDAY_DIR/
       #chmod 755 $BACKUP_REPOS/$YESTERDAY_DIR/$mod_name
       
##--------------------------------------CLOSE LOG----------------------------------------
        #output the start and end time to the end of the log file
        echo -e "\n\nStart Time: $start_time" >> $log
        echo -n "End Time:" >> $log
        date >> $log
        
        #output the difference sizes from current and latest in log
        end_size=$(du -sm "$BACKUP_REPOS/$host_label/latest/$mod_name/" | cut -f1)
        if $DEBUG ; then echo -e "Start size = $start_size   End size = $end_size" >> $DEBUG_LOG ; fi #DEBUG
        echo -e "\n\nAmount Transferred (MB): $(( $end_size - $start_size ))" >> $log
        
        echo "..." >> $log
        echo "..." >> $log
        
        
##--------------------------GET AND CHECK BACKUP DIRECTORIES----------------------
        #save yesterdays backup directory for later use
        #CHANGE TO YESTERDAY_DIR
        curr_yester_dir=$BACKUP_REPOS/$host_label/$YESTERDAY_DIR/$mod_name
        
        #TODO WHY DOESN't MODULE 1 HAVE A NULL LOG
        #Rsync will not make the backup directory if there is nothing to backup. If it doesn't exist yet,
        #let's make the directory and leave a note that no files have changed for that module today.
        if ! $DEBUG ; then #DEBUG
            if [[ ! -d $curr_yester_dir ]]; then
                mkdir -p $curr_yester_dir
                #TODO this adds log files together if ran twice in one day
                #TODO WE PUT FILES IN WITH NULL EVEN IF WE DONT NEED TO
                echo "No files have changed on $host_label for module \"$mod_name\" since the last backup." \
                    > $curr_yester_dir/null_backup.$host_label.$mod_name
                
                if [[ -e "$BACKUP_REPOS/$host_label.$mod_name.log" ]] ; then
                    rm -f "$BACKUP_REPOS/$host_label.$mod_name.log"
                fi
            #Move the yesterdays log file from temp location to backed up directory if it exists
            elif [[ -e "$BACKUP_REPOS/$host_label.$mod_name.log" ]] ; then
                mv "$BACKUP_REPOS/$host_label.$mod_name.log" $curr_yester_dir
            fi
        fi #DEBUG
         
##---------------------GET DAYS UNTIL OBSOLESENCE AND DIRECTORIES TO CHECK----------------------------
        #delete backups that are older than the num of Keepdays
        keepdays=$(cut -d " " -f2- <<< $mod_line|grep -Eo '[0-9]{1,4}')\
          || keepdays=${DEFAULT_KEEPDAYS}

        #get a list of the date directories in descending (newer -> older) order
        #dir_list=$(ls $BACKUP_REPOS/$host_label/$mod_name | grep [0-9] | sort -rn)
        pushd $(pwd) > /dev/null
        cd $BACKUP_REPOS
        dir_list=$(find $host_label -maxdepth 2 -type d | grep $mod_name$ | cut -d '/' -f2 | grep "^20"| sort -rn)
        #dir_list=$(find $host_label -maxdepth 2 -type d | grep $mod_name$ | grep -v latest)
        #if $DEBUG ; then echo "Sending dir_list host:$host_label mod:$mod_name into chk_del" >> $DEBUG_LOG ; fi #DEBUG
        
        #Check the directory list and delete everything
        #in this module older than the number of keepdays
        chk_del_dir_list $dir_list $keepdays
        
        popd > /dev/null
        echo "..." >> $log
        echo "End log for $host_label.$mod_name" >> $log
    done <${module_list}
}






#-----------------------------------------------------------------------
# get the name of the host
#
#       Arguments:
#           $1: host as read in from file
#
#       Returns:
#           a usable label for the host
#---------------------------------- -------------------------------------
function get_host_label()
{
     
    if [[ "$1" == "localhost" ]] ; then
        host_label=$(hostname -s | tr '[a-z]' '[A-Z]')
    else
        # host_label holds either IP of host or host name
        host_label=$(check_host $1)
        
        if [[ -z  ${host_label} ]] ; then
            echo -e "\nERROR Host: $host returned invalid host_check ... trying next host" 1>&2
            echo -e "\thost is either down or not a valid hostname" 1>&2
            continue
        fi
        
        if ! $DEBUG ; then echo -e "\n\nHost folder name will be: \"$host_label\"" >> $DEBUG_LOG ; fi #DEBUG
    fi
    echo $host_label
}






#-----------------------------------------------------------------------
# Get the rsync options based on the host and module
#
#       Arguments:
#           $1: host_label either the IP or name of the host
#           $2: a name of the current module
#---------------------------------- -------------------------------------
function get_rsync_opts()
{
    host_label="$1"
    mod_name="$2"
    
    ##-------------------------CHANGE RSYNC OPTIONS FOR THIS HOST-----------------------
    #Add exclusions if there are any (using the host label 
    #because those are the only valid directory names)
    if [[ -e $EXCLUDE$host_label ]]; then
       if $DEBUG ; then echo -e "\n\nDEBUG: exclude $EXCLUDE$host_label" >> $DEBUG_LOG ; fi  #DEBUG
       rsync_opt="$RSYNC_GLOBALOPTIONS --exclude-from=$EXCLUDE$host_label"
    else
       rsync_opt="$RSYNC_GLOBALOPTIONS"
    fi
    
    if [[ host_label != $(hostname -s | tr '[a-z]' '[A-Z]') ]] ; then
        #set directory to move yesterday's backup
        rsync_opt="$rsync_opt --backup --backup-dir=$BACKUP_REPOS/$host_label/$YESTERDAY_DIR/$mod_name/"
    fi

    echo $rsync_opt
}





#-----------------------------------------------------------------------
#Write the backup log that we will send to the webmaster (via a different script chronos)
#any thing on std_out will be sent
#---------------------------------- -------------------------------------
function process_logs()
{
    local hosts=$1
    local host_labels=$2

    echo ""
    echo "--------------------------------------------------------------------------------"
    echo " Errors: "
    echo "--------------------------------------------------------------------------------"
    echo ""
    grep -A2 "rsync error\|IO error\|skipping"  $LOG_DIR/*
    echo ""
    echo "--------------------------------------------------------------------------------"
#    echo " $BACKUP_VOL useage"
    echo " $(hostname|tr '[a-z]' '[A-Z]'|awk -F. '{print $1}'):$BACKUP_VOL useage"
    echo "--------------------------------------------------------------------------------"
    echo ""
    df -h | grep "$BACKUP_VOL" |awk '{print "Using " $3 " of " $2 " (" $5 "), " $4 " free."}'
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo " Total transferred bytes per host and module: "
    echo "--------------------------------------------------------------------------------"
    echo ""
    grep 'Total transferred file size:' $LOG_DIR/* | cut -d ":" -f1,3 | cut -d "/" -f 4-
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo " Directory sizes for $BACKUP_REPOS/latest/ by host and module: "
    echo "--------------------------------------------------------------------------------"
    echo ""
    for host in $host_labels ; do
        du -ch --max-depth=1 $BACKUP_REPOS/$host/latest
    done
    
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo " Last night incremental backup directory sizes by host and module: "
    echo "--------------------------------------------------------------------------------"
    echo ""
    for host in $host_labels ; do
        du -ch --max-depth=1 $BACKUP_REPOS/$host/$YESTERDAY_DIR
    done
    #/usr2/backup/`date --date="2 days ago" +%Y-%m-%d--%a`
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo " Current number of days we keep incremental backups by host and module: "
    echo "--------------------------------------------------------------------------------"
    echo ""
    for host in $hosts ; do
        echo "$host : "
        rsync ${host}::
    done
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo " End of Report "
    echo "--------------------------------------------------------------------------------"
}




#=======================================================================
# <<<<<< Program starts here >>>>>>
#=======================================================================

# ------------- Initialization And Setup -----------------
# Set file creation mask so that all files are created with 600 permissions.
umask 066
root_check

# Trap TERM, HUP, and INT signals and properly exit
trap "signal_exit TERM" TERM HUP
trap "signal_exit INT"  INT





# ---------------- Command Line Processing ------------------

# check command line arguments and see if help text is
# requested, if so, display it.
if [ "$1" = "--help" -o "$1" = "-h" ] ; then
    helptext
    graceful_exit
fi

#Boolean to let us know if we're reading in the
#hosts from file
read_from_file=false



#TODO MOVE FIX ORDER OF OPTIONS AND DEFAULT CHECKING
#TODO add debug as an option
#TODO LIMIT SO ONLY -S OR -F CAN HAPPEN NOT BEIDES
#-----------------------------Command line options--------------------------------------
#Loop through the command line arguments looking for viable options
while getopts ":s:f:d" opt; do
   case $opt in
      s )   #option for single host to be used, not read in from
            #the command line (this will then exclude the host file)
            hosts_to_backup=${OPTARG}
            if $DEBUG ; then echo "DEBUG: host name arg assigned" ; fi  #DEBUG
            #file_flag=0
            ;;     
      f )
            #option for non-default host file name read from
            #command line (then exludes -s as an option)
            if [[ -n $hosts_to_backup ]] ; then
                host_list_file=${OPTARG}
                if [[ -f "$host_list_file" ]]; then
                    if [[ -s "$host_list_file" ]]; then
                        read_from_file=true
                    else
                        error_exit "${host_list_file} exists, but is empty."
                    fi
                else
                    error_exit "${host_list_file} missing. Check command line."
                fi
            fi
            ;;
      d )
            DEBUG=true
            ;;
      * )
            error_exit "Invalid command line option."
            ;;
   esac
done



if $DEBUG ; then  #DEBUG
    echo "---------DEBUG MODE----------" #DEBUG
    echo "check $DEBUG_LOG_DIR/$DEBUG_LOG for debug messages" #DEBUG
    if [[ ! -d $DEBUG_LOG_DIR ]] ;then #DEBUG
        mkdir $DEBUG_LOG_DIR #DEBUG
    fi #DEBUG
    DEBUG_LOG=$DEBUG_LOG_DIR/$DEBUG_LOG #DEBUG
    if [[ -f $DEBUG_LOG ]] ; then #DEBUG
        rm -f $DEBUG_LOG #DEBUG
    fi
fi   #DEBUG



# ------------------------------------------------------------------------


#---------------------CHECK FOR DEFAULT HOST READ-IN----------------------
#if there are no cmd line args then
#check to see if we have a default list of hosts
#and check if it is valid
if [[ -z $hosts_to_backup && -z $host_list_file ]]; then
    echo "Getting default host list"
    if [ -z "$LIST_OF_HOSTS" ]; then
        usage
        clean_up
        exit 1
    elif [[ -f "$LIST_OF_HOSTS" ]]; then
        if [[ -s "$LIST_OF_HOSTS" ]]; then
            read_from_file=true
            host_list_file=${LIST_OF_HOSTS}
            if $DEBUG ; then echo "DEBUG: host list file found and usable" >> $DEBUG_LOG ; fi #DEBUG
        else
            error_exit "${LIST_OF_HOSTS} is empty."
        fi
    else
        error_exit "${LIST_OF_HOSTS} missing. Check default setting."
    fi
fi


# -------------------- Main Logic -------------------------------




#if we're reading hosts in from a file
#trim out comments and check to see if the
#file has anything left in it
if $read_from_file ; then
    if $DEBUG ; then echo -e "\n\nDEBUG: reading in from a file" >> $DEBUG_LOG ; fi   #DEBUG
    hosts_to_backup=$(awk '!/^#.*/ {print $1}' $host_list_file)
    #hosts_to_backup=${hosts_to_backup}"\n"$(awk '!/^#.*/ {print $1}' $host_list_file)
    if [[ -z $hosts_to_backup ]] ; then
        error_exit "No hosts to back up."
    fi
elif $DEBUG ; then echo -e "\n\nDEBUG: we're not reading in from a file"  >> $DEBUG_LOG  #DEBUG
fi

#this may echo with leading whitespace (newline and/or spaces)
#but it will be trimmed out by the following for loop
echo -e "\nWe will back up:\n${hosts_to_backup}"


## -------------------------BEGIN LOGIC ON HOSTS ------------------------

## TODO ITS POSSIBLE TO MOVE THIS TO SEPARATE FUNCTION
for host in ${hosts_to_backup}; do
    echo  "Backing up host: $host"
 

    #TODO DELETE THESE COMMENTS IF IT WORKS OUT
    #TODO do we have host names with other symbols? e.g. '@'
    #TODO THE WAY we check these invalid characters would leave them in
    #           thats nuts
    #trims out everything thats not alphanumeric, '.' or '-'
    #if that leaves nothing the hostname is invalid
    #$host=$(echo $host | tr -cd "[.-a-zA-Z0-9]")
    #if [[ $(echo "$host" | tr -cd "[.-a-zA-Z0-9]" | grep "[[:alnum:]]") == "" ]] ; then
    #    echo -e "\n\nhostname: $host is not a valid name ... trying next host" ;
    #    continue
    #fi
    if $DEBUG ; then echo -e "\n\n\n--------------------- in hosts for loop checking host: $host-------------------" >> $DEBUG_LOG ; fi   #DEBUG
    
    host_label=$(get_host_label ${host});
    
    valid_hosts+="$host "
    valid_host_labels+="$host_label "
##---------------------GET MODULE LIST AND CALL MODULE FUNCTION------------------------
    #create a temp file to store the module names
    mod_list_file=$(make_temp_file ${host_label})
    temp_file=$mod_list_file
    if $DEBUG ; then echo -e "\n\nDEBUG: temp mod_list_file is \"${mod_list_file}\"" >> $DEBUG_LOG ; fi #DEBUG
    if $DEBUG ; then echo "BACKING UP HOST $host" >> $DEBUG_LOG ; fi   #DEBUG
    if $DEBUG ; then echo "HOST LABEL: " $host_label >> $DEBUG_LOG ; fi   #DEBUG
    
    #grab the module list
    $RSYNC ${host}:: 2>/dev/null|expand|tr -s [:blank:] > ${mod_list_file}
    
    #if the module file has size execute module_logic
    #if not this host doesn't have modules to backup
    if [[ -s $mod_list_file ]] ; then    
        module_logic "$host_label" "$mod_list_file"
    else
        echo "Host: $host has no modules, check /etc/rsync.conf, or rsyncd.conf" 1>&2
    fi
    
    
##------------------------------------------------------------------------------    
    #Remove temp files before we move on to the next host
    
    
    clean_up
done

process_logs "$valid_hosts" "$valid_host_labels"
echo -e "\n\nSNAPBAK COMPLETED SUCCESSFULLY"


graceful_exit

