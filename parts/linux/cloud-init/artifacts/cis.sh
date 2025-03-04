#!/bin/bash

assignRootPW() {
    if grep '^root:[!*]:' /etc/shadow; then
        VERSION=$(grep DISTRIB_RELEASE /etc/*-release | cut -f 2 -d "=")
        SALT=$(openssl rand -base64 5)
        SECRET=$(openssl rand -base64 37)
        CMD="import crypt, getpass, pwd; print(crypt.crypt('$SECRET', '\$6\$$SALT\$'))"
        if [[ "${VERSION}" == "22.04" ]]; then
            HASH=$(python3 -c "$CMD")
        else
            HASH=$(python -c "$CMD")
        fi

        echo 'root:'$HASH | /usr/sbin/chpasswd -e || exit $ERR_CIS_ASSIGN_ROOT_PW
    fi
}

assignFilePermissions() {
    FILES="
    auth.log
    alternatives.log
    cloud-init.log
    cloud-init-output.log
    daemon.log
    dpkg.log
    kern.log
    lastlog
    waagent.log
    syslog
    unattended-upgrades/unattended-upgrades.log
    unattended-upgrades/unattended-upgrades-dpkg.log
    azure-vnet-ipam.log
    azure-vnet-telemetry.log
    azure-cnimonitor.log
    azure-vnet.log
    kv-driver.log
    blobfuse-driver.log
    blobfuse-flexvol-installer.log
    landscape/sysinfo.log
    "
    for FILE in ${FILES}; do
        FILEPATH="/var/log/${FILE}"
        DIR=$(dirname "${FILEPATH}")
        mkdir -p ${DIR} || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
        touch ${FILEPATH} || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
        chmod 640 ${FILEPATH} || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    done
    find /var/log -type f -perm '/o+r' -exec chmod 'g-wx,o-rwx' {} \;
    chmod 600 /etc/passwd- || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    chmod 600 /etc/shadow- || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    chmod 600 /etc/group- || exit $ERR_CIS_ASSIGN_FILE_PERMISSION

    if [[ -f /etc/default/grub ]]; then
        chmod 644 /etc/default/grub || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    fi

    if [[ -f /etc/crontab ]]; then
        chmod 0600 /etc/crontab || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    fi
    for filepath in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d; do
        chmod 0600 $filepath || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    done

    # Docs: https://www.man7.org/linux/man-pages/man1/crontab.1.html
    # If cron.allow exists, then cron.deny is ignored. To minimize who can use cron, we
    # always want cron.allow and will default it to empty if it doesn't exist.
    # We also need to set appropriate permissions on it.
    # Since it will be ignored anyway, we delete cron.deny.
    touch /etc/cron.allow || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    chmod 640 /etc/cron.allow || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
    rm -rf /etc/cron.deny || exit $ERR_CIS_ASSIGN_FILE_PERMISSION
}

# Helper function to replace or append settings to a setting file.
# This abstracts the general logic of:
#   1. Search for the setting (via a pattern passed in).
#   2. If it's there, replace it with desired setting line; otherwise append it to the end of the file.
#   3. Validate that there is now exactly one instance of the setting, and that it is the one we want.
replaceOrAppendSetting() {
    local SEARCH_PATTERN=$1
    local SETTING_LINE=$2
    local FILE=$3

    # Search and replace/append.
    if grep -E "$SEARCH_PATTERN" "$FILE" >/dev/null; then
        sed -E -i "s|${SEARCH_PATTERN}|${SETTING_LINE}|g" "$FILE" || exit $ERR_CIS_APPLY_PASSWORD_CONFIG
    else
        echo -e "\n${SETTING_LINE}" >>"$FILE"
    fi

    # After replacement/append, there should be exactly one line that sets the setting,
    # and it must have the value we want.
    # If not, then there's something wrong with this script.
    if [[ $(grep -E "$SEARCH_PATTERN" "$FILE") != "$SETTING_LINE" ]]; then
        echo "replacement was wrong"
        exit $ERR_CIS_APPLY_PASSWORD_CONFIG
    fi
}

# Creates the search pattern and setting lines for login.defs settings, and calls through
# to do the replacement. Note that this uses extended regular expressions, so both
# grep and sed need to be called as such.
#
# The search pattern is:
#   '^#{0,1} {0,1}' -- Line starts with 0 or 1 '#' followed by 0 or 1 space
#   '${1}\s+'       -- Then the setting name followed by one or more whitespace characters
#   '[0-9]+$'       -- Then one more more number, which is the setting value, which is the end of the line.
#
# This is based on a combination of the syntax for the file and real examples we've found.
replaceOrAppendLoginDefs() {
    replaceOrAppendSetting "^#{0,1} {0,1}${1}\s+[0-9]+$" "${1} ${2}" /etc/login.defs
}

# Creates the search pattern and setting lines for useradd default settings, and calls through
# to do the replacement. Note that this uses extended regular expressions, so both
# grep and sed need to be called as such.
#
# The search pattern is:
#   '^#{0,1} {0,1}' -- Line starts with 0 or 1 '#' followed by 0 or 1 space
#   '${1}='         -- Then the setting name followed by '='
#   '.*$'           -- Then 0 or nore of any character which is the end of the line.
#                      Note that this allows for a setting value to be there or not.
#
# This is based on a combination of the syntax for the file and real examples we've found.
replaceOrAppendUserAdd() {
    replaceOrAppendSetting "^#{0,1} {0,1}${1}=.*$" "${1}=${2}" /etc/default/useradd
}

setPWExpiration() {
    replaceOrAppendLoginDefs PASS_MAX_DAYS 90
    replaceOrAppendLoginDefs PASS_MIN_DAYS 7
    replaceOrAppendUserAdd INACTIVE 30
}

# Creates the search pattern and setting lines for the core dump settings, and calls through
# to do the replacement. Note that this uses extended regular expressions, so both
# grep and sed need to be called as such.
#
# The search pattern is:
#  '^#{0,1} {0,1}' -- Line starts with 0 or 1 '#' followed by 0 or 1 space
#  '${1}='         -- Then the setting name followed by '='
#  '.*$'           -- Then 0 or nore of any character which is the end of the line.
#
# This is based on a combination of the syntax for the file (https://www.man7.org/linux/man-pages/man5/coredump.conf.5.html)
# and real examples we've found.
replaceOrAppendCoreDump() {
    replaceOrAppendSetting "^#{0,1} {0,1}${1}=.*$" "${1}=${2}" /etc/systemd/coredump.conf
}

configureCoreDump() {
    replaceOrAppendCoreDump Storage none
    replaceOrAppendCoreDump ProcessSizeMax 0
}

fixDefaultUmaskForAccountCreation() {
    replaceOrAppendLoginDefs UMASK 027
}

applyCIS() {
    setPWExpiration
    assignRootPW
    assignFilePermissions
    configureCoreDump
    fixDefaultUmaskForAccountCreation
}

applyCIS

#EOF
