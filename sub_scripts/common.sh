#!/bin/bash

readonly NORMAL=$(printf '\033[0m')
readonly BOLD=$(printf '\033[1m')
readonly faint=$(printf '\033[2m')
readonly UNDERLINE=$(printf '\033[4m')
readonly NEGATIVE=$(printf '\033[7m')
readonly RED=$(printf '\033[31m')
readonly GREEN=$(printf '\033[32m')
readonly ORANGE=$(printf '\033[33m')
readonly BLUE=$(printf '\033[34m')
readonly YELLOW=$(printf '\033[93m')
readonly WHITE=$(printf '\033[39m')

function title()
{
    cat << EOF | tee -a "$complete_log"
${BOLD}
 ===================================
 $1
 ===================================
${NORMAL}
EOF
}

function small_title()
{
    echo -e "\n${BOLD} > ${1}${NORMAL}\n" | tee -a "$complete_log"
}


function debug()
{
    echo "$1" >> "$complete_log"
}

function info()
{
    echo "${1}" | tee -a "$complete_log"
}

function success()
{
    echo "${BOLD}${GREEN}Success: ${1}${NORMAL}" | tee -a "$complete_log"
}

function warning()
{
    echo "${BOLD}${ORANGE}Warning: ${1}${NORMAL}" | tee -a "$complete_log" 2>&1
}

function error()
{
    echo "${BOLD}${RED}Error: ${1}${NORMAL}" | tee -a "$complete_log" 2>&1
}

function critical()
{
    echo "${BOLD}${RED}Critical: ${1}${NORMAL}" | tee -a "$complete_log" 2>&1
    clean_exit 1
}

function report_test_success () {
    echo -e "\n${BOLD}${GREEN}--- SUCCESS ---${NORMAL}\n" | tee -a "$complete_log" 2>&1
}

function report_test_warning () {
    echo -e "\n${BOLD}${ORANGE}--- WARNING ---${NORMAL}\n" | tee -a "$complete_log" 2>&1
}

function report_test_failed () {
    echo -e "\n${BOLD}${RED}--- FAIL ---${NORMAL}\n" | tee -a "$complete_log" 2>&1
}
