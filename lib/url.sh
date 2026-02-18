#!/usr/bin/env bash

_url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
}

_url_encode() {
    local LC_ALL=C
    local string="${1}"
    local length=${#string}
    local res=""

    local i c hex
    for (( i = 0; i < length; i++ )); do
        c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) res+="$c" ;;
            *)
                # 某些环境下 printf '%02X' "'$c" 会输出超出两位的十六进制；只取最后两位，保证 %XX
                hex=$(printf '%02X' "'$c")
                res+="%${hex: -2}"
                ;;
        esac
    done

    printf '%s' "$res"
}

export -f _url_decode _url_encode
