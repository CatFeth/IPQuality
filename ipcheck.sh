#!/usr/bin/env bash
# ==============================================================================
# IPQuality | Dual-Stack (IPv4 + IPv6) Diagnostics
# ==============================================================================

set -uo pipefail
shopt -s extglob

export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C
REPORT_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

STACK_MODE="dual"
CUSTOM_IP=""
MASK_IP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -4|--ipv4) STACK_MODE="4"; shift ;;
        -6|--ipv6) STACK_MODE="6"; shift ;;
        -i|--ip)   CUSTOM_IP="${2:-}"; shift 2 ;;
        -m|--mask) MASK_IP=true; shift ;;
        -h|--help)
            echo "Usage: bash ipcheck.sh [-4|-6] [-i target_ip] [-m]"
            exit 0
            ;;
        *) shift ;;
    esac
done

# --- ANSI Colors ---
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[0;90m'
    readonly C_CYAN=$'\033[1;36m'
    readonly C_BAR=$'\033[0;36m'
    readonly C_GREEN=$'\033[1;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_RED=$'\033[1;31m'
    readonly C_BLUE=$'\033[1;34m'
    readonly C_BADGE=$'\033[1;30;46m'

    readonly BG_GREEN=$'\033[42;30m'
    readonly BG_YELLOW=$'\033[43;30m'
    readonly BG_RED=$'\033[41;97m'
    readonly BG_GRAY=$'\033[100;37m'
else
    readonly C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_BAR=""
    readonly C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_BADGE=""
    readonly BG_GREEN="" BG_YELLOW="" BG_RED="" BG_GRAY=""
fi

readonly CLEAR_LINE=$'\r\033[K'
readonly SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
readonly HEADER_MARK="┃"
readonly LINE_SEP="──────────────────────────────────────────────────────────────────────────────"
readonly UA_BROWSER="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

BASE_TMP=$(mktemp -d -t ipq.XXXXXX)
cleanup() {
    local pid
    for pid in $(jobs -pr 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
    rm -rf -- "$BASE_TMP"
}
trap cleanup EXIT INT TERM

FRAME_IDX=0

# --- Dependencies ---
check_deps() {
    local missing=()
    for cmd in curl jq awk sed tr head cut; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v dig &>/dev/null && ! command -v host &>/dev/null; then
        missing+=("dnsutils")
    fi
    if ((${#missing[@]} > 0)); then
        if ((EUID == 0)); then
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq "${missing[@]}" &>/dev/null
            elif command -v dnf &>/dev/null; then
                dnf install -y -q "${missing[@]}" bind-utils &>/dev/null
            elif command -v yum &>/dev/null; then
                yum install -y -q "${missing[@]}" bind-utils &>/dev/null
            elif command -v apk &>/dev/null; then
                apk add --no-cache "${missing[@]}" bind-tools &>/dev/null
            fi
        else
            printf '%s[✗]%s Missing dependencies: %s. Run as root or install manually.\n' "$C_RED" "$C_RESET" "${missing[*]}" >&2
            exit 1
        fi
    fi
}

wait_with_spinner() {
    local label="$1"
    local total
    total=$(jobs -pr | wc -l)
    ((total == 0)) && return
    if [[ -t 2 ]]; then
        while true; do
            local running
            running=$(jobs -pr | wc -l)
            ((running == 0)) && break
            local frame="${SPINNER_FRAMES[FRAME_IDX % ${#SPINNER_FRAMES[@]}]}"
            FRAME_IDX=$((FRAME_IDX + 1))
            printf '%s %s%s%s  %s %s(%d/%d)%s' \
                "$CLEAR_LINE" "$C_CYAN" "$frame" "$C_RESET" "$label" \
                "$C_DIM" $((total - running)) "$total" "$C_RESET" >&2
            sleep 0.1
        done
        printf '%s' "$CLEAR_LINE" >&2
    else
        wait
    fi
}

print_section() {
    printf '\n %s%s%s %s%s%s\n' "$C_BAR" "$HEADER_MARK" "$C_RESET" "$C_CYAN" "$1" "$C_RESET"
    printf ' %s%s%s\n' "$C_DIM" "$LINE_SEP" "$C_RESET"
}

jq_get() {
    local file="$1" query="$2"
    [[ ! -s "$file" ]] && { printf 'N/A'; return; }
    local res
    res=$(jq -r "(${query}) | if . == null or . == \"\" then \"N/A\" else tostring end" "$file" 2>/dev/null || true)
    [[ -z "$res" ]] && res="N/A"
    printf '%s' "$res"
}

# --- ISO Country Mapper ---
iata_to_country() {
    local iata="${1^^}"
    [[ -z "$iata" || ${#iata} -ne 3 ]] && return
    case "$iata" in
        AMS|EIN|RTM) printf 'NL' ;;
        FRA|MUC|BER|DUS|HAM|STR|CGN|NUE|LEJ|HAJ) printf 'DE' ;;
        ARN|GOT|MMX|BMA) printf 'SE' ;;
        HEL|TMP|OUL) printf 'FI' ;;
        OSL|BGO|SVG|TRD) printf 'NO' ;;
        CPH|BLL|AAL) printf 'DK' ;;
        LHR|LGW|MAN|STN|LTN|EDI|BHX|GLA|BRS) printf 'GB' ;;
        CDG|ORY|MRS|LYS|NCE|TLS|BOD) printf 'FR' ;;
        ZRH|GVA|BSL) printf 'CH' ;;
        VIE|SZG|GRZ) printf 'AT' ;;
        WAW|KRK|GDN|KTW|POZ|WRO) printf 'PL' ;;
        PRG|BRQ) printf 'CZ' ;;
        BUD) printf 'HU' ;;
        OTP|CLJ) printf 'RO' ;;
        SOF) printf 'BG' ;;
        BEG) printf 'RS' ;;
        ZAG) printf 'HR' ;;
        LJU) printf 'SI' ;;
        BTS) printf 'SK' ;;
        RIX) printf 'LV' ;;
        TLL) printf 'EE' ;;
        VNO|KUN) printf 'LT' ;;
        DUB|ORK) printf 'IE' ;;
        BRU|CRL) printf 'BE' ;;
        LUX) printf 'LU' ;;
        MAD|BCN|AGP|VLC|PMI|SVQ|BIO) printf 'ES' ;;
        LIS|OPO) printf 'PT' ;;
        MXP|LIN|FCO|BGY|VCE|BLQ|NAP|TRN|PMO) printf 'IT' ;;
        ATH|SKG) printf 'GR' ;;
        IST|SAW|ESB|AYT|ADB) printf 'TR' ;;
        KBP|IEV|LWO|ODS) printf 'UA' ;;
        SVO|DME|VKO|LED|KZN|SVX|OVB|AER|ROV) printf 'RU' ;;
        TLV|HFA) printf 'IL' ;;
        DXB|AUH|SHJ) printf 'AE' ;;
        JNB|CPT|DUR) printf 'ZA' ;;
        IAD|JFK|EWR|LAX|SFO|SJC|ORD|DFW|MIA|ATL|SEA|DEN|BOS|PHX|IAH|MSP|DTW|PHL|CLT|SLC|LAS|MCO|PDX|BNA|RDU|MCI|CMH|IND|PIT|STL|BUF) printf 'US' ;;
        YYZ|YVR|YUL|YYC|YOW|YEG|YWG|YHZ) printf 'CA' ;;
        GRU|GIG|VCP|BSB|CNF|POA|REC|FOR|SSA|CWB) printf 'BR' ;;
        EZE|AEP|COR) printf 'AR' ;;
        SCL) printf 'CL' ;;
        NRT|HND|KIX|ITM|NGO|FUK|CTS) printf 'JP' ;;
        ICN|GMP|PUS) printf 'KR' ;;
        SIN) printf 'SG' ;;
        HKG) printf 'HK' ;;
        TPE|KHH) printf 'TW' ;;
        BKK|DMK|HKT) printf 'TH' ;;
        KUL|JHB) printf 'MY' ;;
        BOM|DEL|BLR|MAA|HYD|CCU|AMD|PNQ) printf 'IN' ;;
        SYD|MEL|BNE|PER|ADL|CBR) printf 'AU' ;;
        AKL|WLG|CHC) printf 'NZ' ;;
        *) printf '' ;;
    esac
}

# --- UI Badges ---
format_type_badge() {
    local val="${1,,}"
    case "$val" in
        *hosting*|*datacenter*|*dch*|*transit*|*cloud*|*server*|*vpn*|*colocation*)
            printf "${BG_RED} %-8s ${C_RESET}" "Hosting" ;;
        *cdn*|*content*)
            printf "${BG_RED} %-8s ${C_RESET}" "CDN" ;;
        *spider*|*ses*|*crawler*|*bot*)
            printf "${BG_RED} %-8s ${C_RESET}" "Crawler" ;;
        *line*|*fixed*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "Line" ;;
        *isp*|*residential*|*home*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "ISP" ;;
        *mobile*|*mob*|*cellular*|*wireless*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "Mobile" ;;
        *business*|*com*|*commercial*|*corporate*|*org*|*bank*)
            printf "${BG_YELLOW} %-8s ${C_RESET}" "Business" ;;
        *edu*|*university*|*school*)
            printf "${BG_YELLOW} %-8s ${C_RESET}" "Edu" ;;
        *gov*|*mil*)
            printf "${BG_YELLOW} %-8s ${C_RESET}" "Gov" ;;
        *)
            printf "${BG_GRAY} %-8s ${C_RESET}" "N/A" ;;
    esac
}

draw_score_bar() {
    local label="$1" score="$2" disp_val="$3" level_txt="$4"
    local bar_len
    bar_len=$(awk -v s="$score" 'BEGIN { len=int(s * 0.42); if(len<1) len=1; if(len>42) len=42; print len }')
    local bar_color="$BG_GREEN" txt_color="$C_GREEN"

    case "$level_txt" in
        High|VeryHigh|DoS|Risky|HighRisk)
            bar_color="$BG_RED"; txt_color="$C_RED" ;;
        Medium|Elevated|Suspicious)
            bar_color="$BG_YELLOW"; txt_color="$C_YELLOW" ;;
        *)
            bar_color="$BG_GREEN"; txt_color="$C_GREEN" ;;
    esac

    local spaces
    spaces=$(printf "%${bar_len}s" "")
    printf " ${C_CYAN}%-15s${C_RESET}${bar_color}${spaces}${C_RESET} ${txt_color}${C_BOLD}%s (%s)${C_RESET}\n" "${label}:" "$disp_val" "$level_txt"
}

fmt_bool() {
    case "$1" in
        true|Yes|yes|1) printf "${C_RED}${C_BOLD}%-8s${C_RESET}" "Yes" ;;
        false|No|no|0)  printf "${C_GREEN}%-8s${C_RESET}" "No" ;;
        *)              printf "${C_DIM}%-8s${C_RESET}" "N/A" ;;
    esac
}

fmt_reg() {
    if [[ -n "$1" && "$1" != "null" && "$1" != "N/A" && ${#1} -eq 2 ]]; then
        printf "${C_GREEN}%-8s${C_RESET}" "[${1}]"
    else
        printf "${C_DIM}%-8s${C_RESET}" "N/A"
    fi
}

fmt_srv_status() {
    case "$1" in
        Yes)      printf "${BG_GREEN} %-8s ${C_RESET}" "Yes" ;;
        NoPrem)   printf "${BG_RED} %-8s ${C_RESET}" "NoPrem" ;;
        OrigOnly) printf "${BG_YELLOW} %-8s ${C_RESET}" "OrigOnly" ;;
        NoIPv6)   printf "${BG_GRAY} %-8s ${C_RESET}" "NoIPv6" ;;
        Clean*)   printf "${BG_GREEN} %-8s ${C_RESET}" "Clean" ;;
        Captcha*) printf "${BG_YELLOW} %-8s ${C_RESET}" "Captcha" ;;
        Block|*)  printf "${BG_RED} %-8s ${C_RESET}" "Blocked" ;;
    esac
}

fmt_srv_type() {
    case "$1" in
        Native)       printf "${BG_GREEN} %-8s ${C_RESET}" "Native" ;;
        GoogleDB)     printf "${BG_YELLOW} %-8s ${C_RESET}" "GoogleDB" ;;
        ViaDNS|Proxy) printf "${BG_YELLOW} %-8s ${C_RESET}" "ViaDNS" ;;
        200*)         printf "${BG_GREEN} %-8s ${C_RESET}" "200 OK" ;;
        429*)         printf "${BG_YELLOW} %-8s ${C_RESET}" "HTTP 429" ;;
        *)            printf " %-8s " "" ;;
    esac
}

# ==============================================================================
# MAIN ENGINE FOR A SINGLE STACK (-4 or -6)
# ==============================================================================
run_check_for_stack() {
    local IPV_MODE="$1"
    local IPV_LABEL="$2"
    local TARGET_IP="$3"
    local IS_LOCAL_IP="$4"

    local TMP_DIR="$BASE_TMP/${IPV_LABEL}"
    mkdir -p "$TMP_DIR"

    # --- 1. Fetch All 12+ IP Databases in Parallel (IPv4 Resilient) ---
    (
        if [[ -s "$BASE_TMP/mm_token" ]]; then
            local mmt
            mmt=$(<"$BASE_TMP/mm_token")
            curl -sLm 5 -A "$UA_BROWSER" -H "Authorization: Bearer $mmt" \
                "https://geoip.maxmind.com/geoip/v2.1/city/${TARGET_IP}?demo=1" > "$TMP_DIR/maxmind_direct.json"
        fi
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?lang=en" > "$TMP_DIR/maxmind.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://stat.ripe.net/data/prefix-overview/data.json?resource=${TARGET_IP}" > "$TMP_DIR/ripe_asn.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://stat.ripe.net/data/rir-stats-country/data.json?resource=${TARGET_IP}" > "$TMP_DIR/ripe_reg.json"
    ) &

    (
        local url="https://ipinfo.io/widget/demo/${TARGET_IP}"
        [[ "$IPV_MODE" == "-6" ]] && url="https://v6.ipinfo.io/widget/demo/${TARGET_IP}"
        curl -sLm 6 -A "$UA_BROWSER" -H "Referer: https://ipinfo.io/" "$url" > "$TMP_DIR/ipinfo_widget.json"
    ) &

    (
        local reg_key="sb69ksjcajfs4c"
        curl -sLm 6 --compressed -A "$UA_BROWSER" \
            -H "Origin: https://ipregistry.co" -H "Referer: https://ipregistry.co/" \
            "https://api.ipregistry.co/${TARGET_IP}?hostname=true&key=${reg_key}" > "$TMP_DIR/ipregistry.json"
    ) &

    (
        curl -sLm 6 -A "$UA_BROWSER" "https://api.ipapi.is/?q=${TARGET_IP}" > "$TMP_DIR/ipapi_is.json"
        if ! jq -e '.asn' "$TMP_DIR/ipapi_is.json" &>/dev/null; then
            curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?db=ipapi" > "$TMP_DIR/ipapi_is.json"
        fi
    ) &

    curl -sLm 6 -A "$UA_BROWSER" "https://api.ipquery.io/${TARGET_IP}" > "$TMP_DIR/ipquery.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://proxycheck.io/v2/${TARGET_IP}?vpn=1&asn=1&risk=1" > "$TMP_DIR/proxycheck.json" &
    curl -sLm 6 -A "$UA_BROWSER" -H "Origin: https://ip-api.com" "https://demo.ip-api.com/json/${TARGET_IP}?fields=66842623" > "$TMP_DIR/ip_api.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://ipwho.is/${TARGET_IP}" > "$TMP_DIR/ipwhois.json" &

    (
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?db=scamalytics" > "$TMP_DIR/scamalytics.json"
        if ! jq -e '.scamalytics.scamalytics_score' "$TMP_DIR/scamalytics.json" &>/dev/null; then
            curl -sLm 6 -A "$UA_BROWSER" "https://scamalytics.com/ip/${TARGET_IP}" > "$TMP_DIR/scamalytics.html"
        fi
    ) &

    (
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?db=ip2location" > "$TMP_DIR/ip2location.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://api.ip2location.io/?ip=${TARGET_IP}" > "$TMP_DIR/ip2loc_direct.json"
    ) &

    (
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?db=ipdata" > "$TMP_DIR/ipdata.json"
        if ! jq -e '.asn' "$TMP_DIR/ipdata.json" &>/dev/null; then
            local ipd_key
            ipd_key=$(curl -sLm 4 -A "$UA_BROWSER" "https://ipdata.co" 2>/dev/null | grep -oE 'api-key=[a-zA-Z0-9]+' | head -n1 | cut -d= -f2 || true)
            [[ -n "$ipd_key" ]] && curl -sLm 5 -A "$UA_BROWSER" -H "Referer: https://ipdata.co/" "https://api.ipdata.co/${TARGET_IP}?api-key=${ipd_key}" > "$TMP_DIR/ipdata.json"
        fi
    ) &

    curl -sLm 6 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?db=abuseipdb" > "$TMP_DIR/abuseipdb.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://ipinfo.check.place/${TARGET_IP}?db=ipqualityscore" > "$TMP_DIR/ipqs.json" &

    (
        if ((IS_LOCAL_IP == 1)); then
            local dbip_key
            dbip_key=$(curl -sL "$IPV_MODE" -m 4 -A "$UA_BROWSER" "https://db-ip.com/api/core/" 2>/dev/null | sed -n 's/.*data-api-key="\([^"]*\)".*/\1/p' | head -n1 || true)
            [[ -n "$dbip_key" ]] && curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -H "Origin: https://db-ip.com" -H "Referer: https://db-ip.com/" \
                "https://api.db-ip.com/v2/${dbip_key}/self" > "$TMP_DIR/dbip.json"
        fi
        [[ ! -s "$TMP_DIR/dbip.json" ]] && curl -sLm 5 -A "$UA_BROWSER" "https://api.db-ip.com/v2/free/${TARGET_IP}" > "$TMP_DIR/dbip.json"
    ) &

    (
        if command -v dig &>/dev/null; then
            dig +short -x "$TARGET_IP" 2>/dev/null | head -n1 | sed 's/\.$//' > "$TMP_DIR/ptr.txt"
        elif command -v host &>/dev/null; then
            host "$TARGET_IP" 2>/dev/null | awk '/domain name pointer/ {print $5}' | sed 's/\.$//' | head -n1 > "$TMP_DIR/ptr.txt"
        fi
    ) &

    # --- Services, AI, CDN & Email (When checking local host IP) ---
    if ((IS_LOCAL_IP == 1)); then
        # YouTube & Gemini
        (
            local yt_sw gl prem_res
            yt_sw=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://www.youtube.com/sw.js_data" 2>/dev/null || true)
            gl=$(jq -r '.[0][2][0][0][1] // empty' <<<"${yt_sw#")]}'"}" 2>/dev/null || true)
            prem_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://www.youtube.com/youtubei/v1/browse" \
                -H "Content-Type: application/json" \
                -d '{"context":{"client":{"clientName":"MWEB","clientVersion":"2.20261020.00.00","hl":"en","gl":"US"}},"browseId":"SPunlimited"}' 2>/dev/null || true)

            echo "${gl:-N/A}" > "$TMP_DIR/google_gl"
            if [[ -z "$yt_sw" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_youtube"
            elif [[ "$prem_res" == *"premiumPurchaseButtonRenderer"* ]]; then
                echo "Yes|${gl:-US}|Native" > "$TMP_DIR/srv_youtube"
            else
                echo "NoPrem|${gl:-RU}|GoogleDB" > "$TMP_DIR/srv_youtube"
            fi

            local g_res g_cc=""
            g_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://accounts.google.com/v3/signin/identifier?flowName=GlifSetupAndroid" 2>/dev/null || true)
            [[ "$g_res" =~ name=\"region\"\ value=\"([^\"]*)\" ]] && g_cc="${BASH_REMATCH[1]}"
            [[ -z "$g_cc" ]] && g_cc="$gl"
            if [[ -n "$g_cc" && ! "$g_cc" =~ ^(RU|BY|CN|HK|IR|KP|CU|SY)$ ]]; then
                echo "Yes|${g_cc}|Native" > "$TMP_DIR/ai_gemini"
            else
                echo "Block|${g_cc:-N/A}|GoogleDB" > "$TMP_DIR/ai_gemini"
            fi
        ) &

        # TikTok
        (
            local tt_res tt_reg
            tt_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://www.tiktok.com/api/v1/web-cookie-privacy/config?appId=1988" 2>/dev/null || true)
            tt_reg=$(jq -r '.body.appProps.region // empty' <<<"$tt_res" 2>/dev/null || true)
            if [[ -z "$tt_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_tiktok"
            elif [[ -n "$tt_reg" && ! "$tt_reg" =~ ^(RU|BY|CN|IR|KP|IN)$ ]]; then
                echo "Yes|${tt_reg}|Native" > "$TMP_DIR/srv_tiktok"
            else
                echo "Block|${tt_reg:-N/A}|N/A" > "$TMP_DIR/srv_tiktok"
            fi
        ) &

        # Netflix + Netflix OCA CDN
        (
            local nf_fast nf_reg nf_url node="" iata="" oca_cc=""
            nf_fast=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" 2>/dev/null || true)
            nf_reg=$(jq -r '.client.location.country // empty' <<<"$nf_fast" 2>/dev/null || true)
            oca_cc=$(jq -r '.targets[0].location.country // empty' <<<"$nf_fast" 2>/dev/null || true)
            nf_url=$(jq -r '.targets[0].url // empty' <<<"$nf_fast" 2>/dev/null || true)
            if [[ "$nf_url" =~ ^https://ipv[46]-([a-z0-9]+-([a-z]{3})[0-9]+[a-z0-9-]*)\. ]]; then
                node="${BASH_REMATCH[1]}"
                iata="${BASH_REMATCH[2]^^}"
            fi
            [[ -z "$oca_cc" && -n "$iata" ]] && oca_cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${oca_cc:--}" "${node:-${iata:--}}" > "$TMP_DIR/cdn_netflix"

            local nf_code1
            nf_code1=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null || true)
            if [[ "$nf_code1" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_netflix"
            elif [[ "$nf_code1" == "200" ]]; then
                echo "Yes|${nf_reg:-OK}|Native" > "$TMP_DIR/srv_netflix"
            else
                echo "OrigOnly|${nf_reg:-N/A}|Proxy" > "$TMP_DIR/srv_netflix"
            fi
        ) &

        # Disney+
        (
            local dp_res dp_reg dp_ok
            dp_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
                -H "Authorization: Bearer ZGlzbmV5JmFuZHJvaWQmMS4wLjA.bkeb0m230uUhv8qrAXuNu39tbE_mD5EEhM_NAcohjyA" \
                -H "Content-Type: application/json" \
                -d '{"query":"mutation registerDevice($registerDevice: RegisterDeviceInput!) { registerDevice(registerDevice: $registerDevice) { __typename } }","variables":{"registerDevice":{"applicationRuntime":"android","attributes":{"operatingSystem":"Android","operatingSystemVersion":"13"},"deviceFamily":"android","deviceLanguage":"en","deviceProfile":"phone","devicePlatformId":"android"}},"operationName":"registerDevice"}' 2>/dev/null || true)
            dp_reg=$(jq -r '.extensions.sdk.session.location.countryCode // empty' <<<"$dp_res" 2>/dev/null || true)
            dp_ok=$(jq -r '.extensions.sdk.session.inSupportedLocation // empty' <<<"$dp_res" 2>/dev/null || true)
            if [[ -z "$dp_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_disney"
            elif [[ "$dp_ok" == "true" ]]; then
                echo "Yes|${dp_reg}|Native" > "$TMP_DIR/srv_disney"
            else
                echo "Block|${dp_reg:-N/A}|N/A" > "$TMP_DIR/srv_disney"
            fi
        ) &

        # Spotify
        (
            local sp_res sp_reg sp_ok
            sp_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -H "X-Client-Id: 9a8d2f0ce77a4e248bb71fefcb557637" \
                "https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=142b583129b2df829de3656f9eb484e6" 2>/dev/null || true)
            sp_reg=$(jq -r '.country // empty' <<<"$sp_res" 2>/dev/null || true)
            sp_ok=$(jq -r '.is_country_launched // empty' <<<"$sp_res" 2>/dev/null || true)
            [[ "$sp_ok" == "true" ]] && echo "Yes|${sp_reg}|Native" > "$TMP_DIR/srv_spotify" || echo "Block|${sp_reg:-N/A}|N/A" > "$TMP_DIR/srv_spotify"
        ) &

        # Twitch
        (
            local tw_res tw_reg
            tw_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://gql.twitch.tv/gql" \
                -H "Client-Id: kimne78kx3ncx6brgo4mv6wki5h1ko" -H "Content-Type: application/json" \
                -d '[{"operationName":"VerifyEmail_CurrentUser","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f9e7dcdf7e99c314c82d8f7f725fab5f99d1df3d7359b53c9ae122deec590198"}}}]' 2>/dev/null || true)
            tw_reg=$(jq -r '.[0].data.requestInfo.countryCode // empty' <<<"$tw_res" 2>/dev/null || true)
            if [[ -z "$tw_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_twitch"
            elif [[ -n "$tw_reg" ]]; then
                echo "Yes|${tw_reg}|Native" > "$TMP_DIR/srv_twitch"
            else
                echo "Block|N/A|N/A" > "$TMP_DIR/srv_twitch"
            fi
        ) &

        # ChatGPT / OpenAI
        (
            local oa_res oa_code oa_reg=""
            oa_res=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -X POST -H "Statsig-Api-Key: client-zUdXdSTygXJdzoE0sWTkP8GKTVsUMF2IRM7ShVO2JAG" "https://ab.chatgpt.com/v1/initialize" 2>/dev/null || true)
            [[ "$oa_res" =~ \"derived_fields\":\{[^\}]*\"country\":\"([^\"]*)\" ]] && oa_reg="${BASH_REMATCH[1]}"
            oa_code=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.openai.com/v1/models" 2>/dev/null || true)
            [[ "$oa_code" == "401" ]] && echo "Yes|${oa_reg:-OK}|Native" > "$TMP_DIR/ai_chatgpt" || echo "Block|${oa_reg:-N/A}|N/A" > "$TMP_DIR/ai_chatgpt"
        ) &

        # Claude
        (
            local cl_res cl_code cl_reg
            cl_res=$(curl -sL "$IPV_MODE" -m 5 -A "Claude com.anthropic.claude/1.261023.20 (Android 30) Claude/1.261023.20" \
                -H "Anthropic-Client-Platform: android" "https://claude.ai/api/bootstrap" 2>/dev/null || true)
            cl_reg=$(jq -r '.statsig.user.country // empty' <<<"$cl_res" 2>/dev/null || true)
            cl_code=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.anthropic.com/v1/models" 2>/dev/null || true)
            [[ "$cl_code" == "401" ]] && echo "Yes|${cl_reg:-OK}|Native" > "$TMP_DIR/ai_claude" || echo "Block|${cl_reg:-N/A}|N/A" > "$TMP_DIR/ai_claude"
        ) &

        # Grok (xAI)
        (
            local gk_code
            gk_code=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.x.ai/v1/models" 2>/dev/null || true)
            [[ "$gk_code" == "401" ]] && echo "Yes|OK|Native" > "$TMP_DIR/ai_copilot" || echo "Block|N/A|N/A" > "$TMP_DIR/ai_copilot"
        ) &

        # Cloudflare CDN + Web
        (
            local cf_meta cf_cc cf_iata
            cf_meta=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -H "Referer: https://speed.cloudflare.com" "https://speed.cloudflare.com/meta" 2>/dev/null || true)
            cf_cc=$(jq -r '.colo.cca2 // empty' <<<"$cf_meta" 2>/dev/null || true)
            cf_iata=$(jq -r '.colo.iata // empty' <<<"$cf_meta" 2>/dev/null || true)
            printf '%s|%s\n' "${cf_cc:--}" "${cf_iata:--}" > "$TMP_DIR/cdn_cloudflare"
            if [[ -n "$cf_iata" ]]; then
                echo "Clean|${cf_cc:-OK}|200 OK" > "$TMP_DIR/cdn_cf"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/cdn_cf"
            fi
        ) &

        # YouTube GGC CDN + Fastly + CloudFront
        (
            local yt_map node="" iata="" cc=""
            yt_map=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://redirector.googlevideo.com/report_mapping?di=no" 2>/dev/null || true)
            [[ "$yt_map" =~ =\>\ ([^[:space:]]+) ]] && node="${BASH_REMATCH[1]}"
            node="${node%%.*}"
            if [[ "$node" =~ ^([a-z]{3})[0-9] || "$node" =~ ^[a-z]+-([a-z]{3})[0-9] || "$node" =~ ^[a-z]{2}([a-z]{3})[a-z]-[a-z0-9]+$ ]]; then
                iata="${BASH_REMATCH[1]^^}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${node:-${iata:--}}" > "$TMP_DIR/cdn_youtube"
        ) &
        (
            local fs_hdr pop="" iata="" cc=""
            fs_hdr=$(curl -sIL "$IPV_MODE" -m 5 -A "$UA_BROWSER" "https://www.fastly.com/robots.txt" 2>/dev/null | tr -d '\r' || true)
            if [[ "$fs_hdr" =~ [Xx]-[Ss]erved-[Bb]y:\ *([^[:space:],]+) ]]; then
                pop="${BASH_REMATCH[1]#cache-}"
                [[ "$pop" =~ -([A-Z]{3})$ ]] && iata="${BASH_REMATCH[1]}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${pop:--}" > "$TMP_DIR/cdn_fastly"
        ) &

        # Google Search
        (
            local gs_out
            gs_out=$(curl -sL "$IPV_MODE" -m 5 -A "$UA_BROWSER" -H "Cookie: SOCS=CAI" -w "\nCODE:%{http_code}\nREDIR:%{redirect_url}" "https://www.google.com/search?q=cats" 2>/dev/null || true)
            if [[ "$gs_out" == *"/sorry/"* || "$gs_out" == *"CODE:429"* ]]; then
                echo "Captcha|N/A|429" > "$TMP_DIR/cdn_google"
            elif [[ "$gs_out" == *"enablejs"* ]]; then
                echo "Clean|OK|200 OK" > "$TMP_DIR/cdn_google"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/cdn_google"
            fi
        ) &

        # Port 25 & MX Reachability
        (
            local mx_addr
            if [[ "$IPV_MODE" == "-4" ]]; then
                mx_addr=$(dig +short A gmail-smtp-in.l.google.com 2>/dev/null | head -n1 || true)
            else
                mx_addr=$(dig +short AAAA gmail-smtp-in.l.google.com 2>/dev/null | head -n1 || true)
            fi
            if [[ -n "$mx_addr" ]] && timeout 3 bash -c "</dev/tcp/${mx_addr}/25" &>/dev/null; then
                echo "Open" > "$TMP_DIR/p25_local"
            else
                echo "Block" > "$TMP_DIR/p25_local"
            fi
        ) &

        for m_item in "Gmail|gmail-smtp-in.l.google.com" "Outlook|outlook-com.olc.protection.outlook.com" "Yahoo|mta5.am0.yahoodns.net" "Apple|mx01.mail.icloud.com" "Proton|mail.protonmail.ch" "Yandex|mx.yandex.ru" "Mail.ru|mxs.mail.ru" "Zoho|mx.zoho.com"; do
            (
                IFS='|' read -r m_name m_host <<<"$m_item"
                local target_addr=""
                if [[ "$IPV_MODE" == "-4" ]]; then
                    target_addr=$(dig +short A "$m_host" 2>/dev/null | head -n1 || true)
                else
                    target_addr=$(dig +short AAAA "$m_host" 2>/dev/null | head -n1 || true)
                fi
                if [[ -z "$target_addr" ]]; then
                    echo "NoIPv6" > "$TMP_DIR/mail_${m_name}"
                else
                    if timeout 3 bash -c "</dev/tcp/${target_addr}/25" &>/dev/null; then
                        echo "Yes" > "$TMP_DIR/mail_${m_name}"
                    else
                        echo "No" > "$TMP_DIR/mail_${m_name}"
                    fi
                fi
            ) &
        done
    fi

    # --- DNSBL Checks ---
    local REV_IP=""
    if [[ "$TARGET_IP" == *":"* ]]; then
        command -v python3 &>/dev/null && REV_IP=$(python3 -c "import ipaddress; print('.'.join(reversed(ipaddress.ip_address('$TARGET_IP').exploded.replace(':',''))))" 2>/dev/null || true)
    else
        REV_IP=$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$TARGET_IP")
    fi

    local RBL_LIST="zen.spamhaus.org b.barracudacentral.org bl.spamcop.net dnsbl.sorbs.net dnsbl-1.uceprotect.net psbl.surriel.com db.wpbl.info ix.dnsbl.manitu.net 0spam.fusionzero.com rbl.interserver.net"
    local RBL_TOTAL=10
    mkdir -p "$TMP_DIR/rbl"

    if [[ -n "$REV_IP" ]]; then
        for rbl in $RBL_LIST; do
            (
                local res=""
                if command -v dig &>/dev/null; then
                    res=$(dig +short +time=2 +tries=1 "${REV_IP}.${rbl}" A 2>/dev/null | grep -E '^127\.0\.0\.[0-9]+$' || true)
                elif command -v host &>/dev/null; then
                    res=$(host -W 2 "${REV_IP}.${rbl}" 2>/dev/null | grep -oE '127\.0\.0\.[0-9]+' || true)
                fi
                [[ -n "$res" && "$res" != "127.0.0.255" ]] && echo "$rbl" > "$TMP_DIR/rbl/${rbl}"
            ) &
        done
    fi

    wait_with_spinner "Checking ${IPV_LABEL} quality (${TARGET_IP})"

    # ==========================================================================
    # PARSE DATA FOR REPORT
    # ==========================================================================
    local ASN ORG CITY POSTAL COUNTRY_CODE COUNTRY_NAME REG_COUNTRY TIMEZONE LAT_LON PTR_RECORD

    ASN=$(jq -r '.traits.autonomous_system_number // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.ASN.AutonomousSystemNumber // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.data.asns[0].asn // empty' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
    [[ -n "$ASN" ]] && ASN="AS${ASN}"
    [[ -z "$ASN" ]] && ASN=$(jq -r '.data.asn.asn // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$ASN" ]] && ASN=$(jq -r '.as // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null | awk '{print $1}')

    ORG=$(jq -r '.traits.autonomous_system_organization // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.ASN.AutonomousSystemOrganization // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.data.asns[0].holder // empty | sub("^\\S+ (- )?"; "")' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
    [[ -z "$ORG" ]] && ORG=$(jq -r '.data.asn.name // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$ORG" ]] && ORG=$(jq -r '.org // .isp // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null || true)

    CITY=$(jq -r '.city.names.en // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r '.City.Name // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$CITY" ]] && CITY=$(jq -r '.data.city // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$CITY" ]] && CITY=$(jq -r '.city // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null || true)

    POSTAL=$(jq -r '.postal.code // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$POSTAL" || "$POSTAL" == "null" ]] && POSTAL=$(jq -r '.City.PostalCode // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$POSTAL" ]] && POSTAL=$(jq -r '.data.postal // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)

    COUNTRY_CODE=$(jq -r '.country.iso_code // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r '.Country.IsoCode // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" ]] && COUNTRY_CODE=$(jq -r '.countryCode // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" ]] && COUNTRY_CODE=$(jq -r '.data.country // "N/A"' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)

    COUNTRY_NAME=$(jq -r '.country.names.en // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" || "$COUNTRY_NAME" == "null" ]] && COUNTRY_NAME=$(jq -r '.Country.Name // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" ]] && COUNTRY_NAME=$(jq -r '.country // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null || true)

    REG_COUNTRY=$(jq -r '.data.located_resources[0].location // empty' "$TMP_DIR/ripe_reg.json" 2>/dev/null || true)
    [[ -z "$REG_COUNTRY" || "$REG_COUNTRY" == "null" ]] && REG_COUNTRY=$(jq -r '.Country.RegisteredCountry.IsoCode // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$REG_COUNTRY" || "$REG_COUNTRY" == "null" ]] && REG_COUNTRY="$COUNTRY_CODE"

    TIMEZONE=$(jq -r '.location.time_zone // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "null" ]] && TIMEZONE=$(jq -r '.City.Location.TimeZone // empty' "$TMP_DIR/maxmind.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" ]] && TIMEZONE=$(jq -r '.timezone // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null || true)

    LAT_LON=$(jq -r '.data.loc // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    if [[ -z "$LAT_LON" || "$LAT_LON" == "null" ]]; then
        local lat lon
        lat=$(jq -r '.lat // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
        lon=$(jq -r '.lon // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
        [[ -n "$lat" && -n "$lon" ]] && LAT_LON="${lat}, ${lon}"
    fi

    PTR_RECORD=$(cat "$TMP_DIR/ptr.txt" 2>/dev/null || true)
    [[ -z "$PTR_RECORD" ]] && PTR_RECORD="No PTR (Missing rDNS)"

    # --- Parse 12 IP Types ---
    local T_INF_U=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.asn.type')
    local T_INF_C=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.company.type')
    local T_REG_U=$(jq_get "$TMP_DIR/ipregistry.json" '.connection.type')
    local T_REG_C=$(jq_get "$TMP_DIR/ipregistry.json" '.company.type')
    local T_API_U=$(jq_get "$TMP_DIR/ipapi_is.json" '.asn.type')
    local T_API_C=$(jq_get "$TMP_DIR/ipapi_is.json" '.company.type')
    local T_I2L_U=$(jq_get "$TMP_DIR/ip2location.json" '.usage_type')
    local T_I2L_C=$(jq_get "$TMP_DIR/ip2location.json" '.as_info.as_usage_type')
    [[ "$T_I2L_U" == "N/A" && "$(jq_get "$TMP_DIR/ip2loc_direct.json" '.is_proxy')" == "true" ]] && T_I2L_U="hosting"
    local T_IPD_U=$(jq_get "$TMP_DIR/ipdata.json" '.asn.type')
    local T_IPD_C=$(jq_get "$TMP_DIR/ipdata.json" '.company.type')
    [[ "$T_IPD_U" == "N/A" && "$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_datacenter')" == "true" ]] && T_IPD_U="hosting"
    local T_WHO_U=$(jq_get "$TMP_DIR/ipwhois.json" '.connection.type')
    local T_WHO_C="N/A"
    if [[ "$T_WHO_U" == "N/A" && "$(jq_get "$TMP_DIR/ipwhois.json" '.success')" == "true" ]]; then
        if echo "$ORG" | grep -qiE "host|cloud|server|vps|data|dedi|netcup|hetzner|ovh|digitalocean|linode|vultr|leaseweb|choopa|contabo|pq.hosting|aeza|melbicom|datacamp|m247"; then
            T_WHO_U="hosting"; T_WHO_C="hosting"
        else
            T_WHO_U="isp"; T_WHO_C="isp"
        fi
    fi

    local T_MAX_U=$(jq_get "$TMP_DIR/maxmind_direct.json" '.traits.user_type')
    local T_ABU_U=$(jq_get "$TMP_DIR/abuseipdb.json" '.data.usageType')
    local T_PCK_U=$(jq -r --arg ip "$TARGET_IP" '.[$ip].type // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null || echo "N/A")
    local T_IPA_U="N/A"
    if [[ "$(jq_get "$TMP_DIR/ip_api.json" '.status')" == "success" ]]; then
        if [[ "$(jq_get "$TMP_DIR/ip_api.json" '.hosting')" == "true" ]]; then T_IPA_U="hosting"
        elif [[ "$(jq_get "$TMP_DIR/ip_api.json" '.mobile')" == "true" ]]; then T_IPA_U="mobile"
        else T_IPA_U="isp"; fi
    fi
    local T_IPQ_U="N/A"
    if [[ "$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_datacenter')" == "true" ]]; then T_IPQ_U="hosting"
    elif [[ "$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_mobile')" == "true" ]]; then T_IPQ_U="mobile"
    elif jq -e '.isp' "$TMP_DIR/ipquery.json" &>/dev/null; then T_IPQ_U="isp"; fi

    local T_SCM_U="N/A"
    local scm_dc=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_datacenter')
    if [[ "$scm_dc" == "true" ]]; then T_SCM_U="hosting"
    elif [[ "$scm_dc" == "false" ]]; then T_SCM_U="isp"
    elif [[ -s "$TMP_DIR/scamalytics.html" ]]; then
        grep -qiE 'Datacenter.*Yes|Server.*Yes' "$TMP_DIR/scamalytics.html" 2>/dev/null && T_SCM_U="hosting" || T_SCM_U="isp"
    fi

    # --- Parse 10 Risk Scores ---
    local I2L_SCORE=$(jq -r '.fraud_score // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ "$I2L_SCORE" == "null" ]] && I2L_SCORE=""

    local SCAM_SCORE=$(jq -r '.scamalytics.scamalytics_score // empty' "$TMP_DIR/scamalytics.json" 2>/dev/null || true)
    [[ "$SCAM_SCORE" == "null" ]] && SCAM_SCORE=""
    if [[ -z "$SCAM_SCORE" && -s "$TMP_DIR/scamalytics.html" ]]; then
        SCAM_SCORE=$(tr '\n' ' ' < "$TMP_DIR/scamalytics.html" | sed -n 's/.*"score":"\([0-9]*\)".*/\1/p')
        [[ -z "$SCAM_SCORE" ]] && SCAM_SCORE=$(grep -i "Fraud Score:" "$TMP_DIR/scamalytics.html" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
    fi

    local IPQ_SCORE=$(jq -r '.risk.risk_score // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ "$IPQ_SCORE" == "null" ]] && IPQ_SCORE=""

    local IPAPI_RAW=$(jq -r '.company.abuser_score // .asn.abuser_score // empty' "$TMP_DIR/ipapi_is.json" 2>/dev/null || true)
    [[ "$IPAPI_RAW" == "null" ]] && IPAPI_RAW=""
    local IPAPI_PCT="" IPAPI_LVL=""
    if [[ -n "$IPAPI_RAW" ]]; then
        IPAPI_PCT=$(awk '{printf "%.2f", $1 * 100}' <<<"$IPAPI_RAW")
        IPAPI_LVL=$(grep -oE '\([A-Za-z ]+\)' <<<"$IPAPI_RAW" | tr -d '() ' || true)
    fi

    local ABUSE_SCORE=$(jq -r '.data.abuseConfidenceScore // empty' "$TMP_DIR/abuseipdb.json" 2>/dev/null || true)
    [[ "$ABUSE_SCORE" == "null" ]] && ABUSE_SCORE=""

    local IPQS_SCORE=$(jq -r '.fraud_score // empty' "$TMP_DIR/ipqs.json" 2>/dev/null || true)
    [[ "$IPQS_SCORE" == "null" ]] && IPQS_SCORE=""

    local PCHECK_SCORE=$(jq -r --arg ip "$TARGET_IP" '.[$ip].risk // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    [[ "$PCHECK_SCORE" == "null" ]] && PCHECK_SCORE=""

    local IPREG_SCORE=""
    if jq -e '.security' "$TMP_DIR/ipregistry.json" &>/dev/null; then
        IPREG_SCORE=$(jq -r '.security | ((if .is_tor or .is_tor_exit then 50 else 0 end)+(if .is_attacker then 50 else 0 end)+(if .is_abuser then 40 else 0 end)+(if .is_threat then 40 else 0 end)+(if .is_proxy then 30 else 0 end)+(if .is_vpn then 25 else 0 end)+(if .is_cloud_provider then 15 else 0 end)) | if . > 100 then 100 else . end' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    fi

    local IPDATA_SCORE=""
    if jq -e '.threat' "$TMP_DIR/ipdata.json" &>/dev/null; then
        IPDATA_SCORE=$(jq -r '.threat | ((if .is_tor then 50 else 0 end)+(if .is_known_attacker then 50 else 0 end)+(if .is_known_abuser then 40 else 0 end)+(if .is_threat then 40 else 0 end)+(if .is_proxy then 30 else 0 end)+(if .is_vpn then 25 else 0 end)+(if .is_datacenter then 15 else 0 end)) | if . > 100 then 100 else . end' "$TMP_DIR/ipdata.json" 2>/dev/null || true)
    fi

    local DBIP_RAW=$(jq -r '.threatLevel // empty' "$TMP_DIR/dbip.json" 2>/dev/null || true)
    local DBIP_SCORE=""
    case "$DBIP_RAW" in low) DBIP_SCORE=0 ;; medium) DBIP_SCORE=50 ;; high) DBIP_SCORE=100 ;; esac

    # ==========================================================================
    # RENDER VERTICAL REPORT
    # ==========================================================================
    local DISP_IP="$TARGET_IP"
    if [[ "$MASK_IP" == true ]]; then
        [[ "$DISP_IP" == *"."* ]] && DISP_IP="${DISP_IP%.*.*}.*.*" || DISP_IP="${DISP_IP%%:*}:${DISP_IP#*:}" && DISP_IP="${DISP_IP%%:*}::*"
    fi

    printf '\n'
    printf ' %s%s%s %s %s\n' "$C_BAR" "$HEADER_MARK" "$C_RESET" "${C_BADGE} IPQUALITY ${C_RESET}" "${C_BOLD}${IPV_LABEL} Diagnostics Report ( ${DISP_IP} )${C_RESET}"
    printf ' %s%s%s %s\n' "$C_BAR" "$HEADER_MARK" "$C_RESET" "${C_DIM}Report Time: ${REPORT_TIME} · Stack: ${IPV_LABEL}${C_RESET}"

    # --- I. Basic Information ---
    print_section "I. Basic Information (MaxMind / RIPE / IPinfo)"
    printf " ${C_CYAN}%-18s${C_RESET}${C_BOLD}%s${C_RESET} (%s)\n" "IP Address:" "$DISP_IP" "$IPV_LABEL"
    printf " ${C_CYAN}%-18s${C_RESET}%s\n" "ASN:" "${ASN:-N/A}"
    printf " ${C_CYAN}%-18s${C_RESET}%s\n" "Organization:" "${ORG:-N/A}"
    printf " ${C_CYAN}%-18s${C_RESET}%s\n" "Location:" "${CITY:-N/A}${POSTAL:+, $POSTAL}, ${COUNTRY_NAME:-N/A} [${COUNTRY_CODE:-N/A}]"
    printf " ${C_CYAN}%-18s${C_RESET}[%s]\n" "Registered In:" "${REG_COUNTRY:-N/A}"
    printf " ${C_CYAN}%-18s${C_RESET}%s\n" "Time Zone:" "${TIMEZONE:-N/A}"
    printf " ${C_CYAN}%-18s${C_RESET}%s\n" "Coordinates:" "${LAT_LON:-N/A}"
    if [[ "$PTR_RECORD" == "No PTR"* ]]; then
        printf " ${C_CYAN}%-18s${C_RESET}${C_YELLOW}%s${C_RESET}\n" "PTR (rDNS):" "$PTR_RECORD"
    else
        printf " ${C_CYAN}%-18s${C_RESET}${C_GREEN}%s${C_RESET}\n" "PTR (rDNS):" "$PTR_RECORD"
    fi

    # --- II. IP Type (12 Databases, Full Labels) ---
    print_section "II. IP Type (12 Databases)"
    printf " ${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "Database:" "IPinfo" "ipregistry" "ipapi.is" "IP2Loc" "ipdata.co" "ipwho.is"
    printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Usage:" \
        "$(format_type_badge "$T_INF_U")" "$(format_type_badge "$T_REG_U")" "$(format_type_badge "$T_API_U")" \
        "$(format_type_badge "$T_I2L_U")" "$(format_type_badge "$T_IPD_U")" "$(format_type_badge "$T_WHO_U")"
    printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Company:" \
        "$(format_type_badge "$T_INF_C")" "$(format_type_badge "$T_REG_C")" "$(format_type_badge "$T_API_C")" \
        "$(format_type_badge "$T_I2L_C")" "$(format_type_badge "$T_IPD_C")" "$(format_type_badge "$T_WHO_C")"
    printf '\n'
    printf " ${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "Database:" "MaxMind" "AbuseIPDB" "ProxyCheck" "ip-api.com" "ipquery.io" "Scamalytics"
    printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Usage:" \
        "$(format_type_badge "$T_MAX_U")" "$(format_type_badge "$T_ABU_U")" "$(format_type_badge "$T_PCK_U")" \
        "$(format_type_badge "$T_IPA_U")" "$(format_type_badge "$T_IPQ_U")" "$(format_type_badge "$T_SCM_U")"

    # --- III. Risk Score (10 Engines) ---
    print_section "III. Risk Score (10 Engines)"
    printf " ${C_CYAN}%-15s${C_RESET}${BG_GREEN} Low          ${C_RESET}${BG_YELLOW} Medium       ${C_RESET}${BG_RED} High         ${C_RESET}\n" "Risk Levels:"

    if [[ -n "$SCAM_SCORE" ]]; then
        local lvl="Low"; ((SCAM_SCORE >= 25)) && lvl="Medium"; ((SCAM_SCORE >= 60)) && lvl="High"
        draw_score_bar "Scamalytics" "$SCAM_SCORE" "${SCAM_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPQS_SCORE" ]]; then
        local lvl="Low"; ((IPQS_SCORE >= 50)) && lvl="Medium"; ((IPQS_SCORE >= 75)) && lvl="Risky"; ((IPQS_SCORE >= 85)) && lvl="High"
        draw_score_bar "IPQualityScore" "$IPQS_SCORE" "${IPQS_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPQ_SCORE" ]]; then
        local lvl="Low"; ((IPQ_SCORE >= 25)) && lvl="Medium"; ((IPQ_SCORE >= 65)) && lvl="High"
        draw_score_bar "ipquery.io" "$IPQ_SCORE" "${IPQ_SCORE}/100" "$lvl"
    fi
    if [[ -n "$I2L_SCORE" ]]; then
        local lvl="Low"; ((I2L_SCORE >= 25)) && lvl="Medium"; ((I2L_SCORE >= 65)) && lvl="High"
        draw_score_bar "IP2Location" "$I2L_SCORE" "${I2L_SCORE}/100" "$lvl"
    fi
    if [[ -n "$ABUSE_SCORE" ]]; then
        local lvl="Low"; ((ABUSE_SCORE >= 25)) && lvl="Medium"; ((ABUSE_SCORE >= 65)) && lvl="High"
        draw_score_bar "AbuseIPDB" "$ABUSE_SCORE" "${ABUSE_SCORE}/100" "$lvl"
    fi
    if [[ -n "$PCHECK_SCORE" ]]; then
        local lvl="Low"; ((PCHECK_SCORE >= 33)) && lvl="Medium"; ((PCHECK_SCORE >= 66)) && lvl="High"
        draw_score_bar "ProxyCheck.io" "$PCHECK_SCORE" "${PCHECK_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPAPI_PCT" ]]; then
        local bar_num
        bar_num=$(awk '{print int($1 * 15)}' <<<"$IPAPI_PCT")
        draw_score_bar "ipapi.is" "$bar_num" "${IPAPI_PCT}%" "${IPAPI_LVL:-Low}"
    fi
    if [[ -n "$IPREG_SCORE" ]]; then
        local lvl="Low"; ((IPREG_SCORE >= 25)) && lvl="Medium"; ((IPREG_SCORE >= 60)) && lvl="High"
        draw_score_bar "ipregistry.co" "$IPREG_SCORE" "${IPREG_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPDATA_SCORE" ]]; then
        local lvl="Low"; ((IPDATA_SCORE >= 25)) && lvl="Medium"; ((IPDATA_SCORE >= 60)) && lvl="High"
        draw_score_bar "ipdata.co" "$IPDATA_SCORE" "${IPDATA_SCORE}/100" "$lvl"
    fi
    if [[ -n "$DBIP_SCORE" ]]; then
        local lvl="Low"; ((DBIP_SCORE == 50)) && lvl="Medium"; ((DBIP_SCORE == 100)) && lvl="High"
        draw_score_bar "DB-IP" "$DBIP_SCORE" "${DBIP_SCORE}%" "$lvl"
    fi

    # --- IV. Risk Factors Matrix (8 Sources) ---
    print_section "IV. Security & Risk Factors (8 Sources)"
    printf " ${C_CYAN}%-10s${C_RESET}%-8s%-8s%-8s%-8s%-8s%-8s%-8s%-8s\n" "Factor" "IP2Loc" "ipapi" "ipreg" "ipquery" "Scamal" "ipdata" "PCheck" "ip-api"

    local C_I2L=$(jq -r '.country_code // empty' "$TMP_DIR/ip2loc_direct.json" 2>/dev/null || echo "$COUNTRY_CODE")
    local C_API=$(jq -r '.location.country_code // empty' "$TMP_DIR/ipapi_is.json" 2>/dev/null || true)
    local C_REG=$(jq -r '.location.country.code // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    local C_IPQ=$(jq -r '.location.country_code // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    local C_SCM=$(cat "$TMP_DIR/google_gl" 2>/dev/null || true); [[ -z "$C_SCM" || "$C_SCM" == "N/A" ]] && C_SCM="$COUNTRY_CODE"
    local C_IPD=$(jq -r '.country_code // empty' "$TMP_DIR/ipdata.json" 2>/dev/null || true)
    local C_PCK=$(jq -r --arg ip "$TARGET_IP" '.[$ip].isocode // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    local C_IPA=$(jq -r '.countryCode // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Country" \
        "$(fmt_reg "$C_I2L")" "$(fmt_reg "$C_API")" "$(fmt_reg "$C_REG")" "$(fmt_reg "$C_IPQ")" \
        "$(fmt_reg "$C_SCM")" "$(fmt_reg "$C_IPD")" "$(fmt_reg "$C_PCK")" "$(fmt_reg "$C_IPA")"

    local P_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.is_proxy')
    [[ "$P_I2L" == "N/A" ]] && P_I2L=$(jq_get "$TMP_DIR/ip2loc_direct.json" '.is_proxy')
    local P_API=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_proxy')
    local P_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_proxy')
    local P_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_proxy')
    local P_SCM=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_public_proxy')
    local P_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_proxy')
    local P_PCK=$(jq -r --arg ip "$TARGET_IP" '.[$ip].proxy // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    local P_IPA=$(jq_get "$TMP_DIR/ip_api.json" '.proxy')

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Proxy" \
        "$(fmt_bool "$P_I2L")" "$(fmt_bool "$P_API")" "$(fmt_bool "$P_REG")" "$(fmt_bool "$P_IPQ")" \
        "$(fmt_bool "$P_SCM")" "$(fmt_bool "$P_IPD")" "$(fmt_bool "$P_PCK")" "$(fmt_bool "$P_IPA")"

    local V_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_vpn')
    local V_API=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_vpn')
    local V_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_vpn')
    local V_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_vpn')
    local V_SCM=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_vpn')
    local V_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_vpn')
    local V_PCK="No"; [[ "$T_PCK_U" == "VPN" ]] && V_PCK="Yes"

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "VPN" \
        "$(fmt_bool "$V_I2L")" "$(fmt_bool "$V_API")" "$(fmt_bool "$V_REG")" "$(fmt_bool "$V_IPQ")" \
        "$(fmt_bool "$V_SCM")" "$(fmt_bool "$V_IPD")" "$(fmt_bool "$V_PCK")" "$(fmt_bool "N/A")"

    local R_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_tor')
    local R_API=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_tor')
    local R_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_tor')
    local R_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_tor')
    local R_SCM=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_tor_exit_node')
    local R_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_tor')

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Tor" \
        "$(fmt_bool "$R_I2L")" "$(fmt_bool "$R_API")" "$(fmt_bool "$R_REG")" "$(fmt_bool "$R_IPQ")" \
        "$(fmt_bool "$R_SCM")" "$(fmt_bool "$R_IPD")" "$(fmt_bool "No")" "$(fmt_bool "N/A")"

    local S_I2L="No"; [[ "$T_I2L_U" =~ (DCH|SES|hosting) ]] && S_I2L="Yes"
    local S_API=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_datacenter')
    local S_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_cloud_provider')
    local S_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_datacenter')
    local S_SCM=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_datacenter')
    local S_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_datacenter')
    local S_PCK="No"; [[ "$T_PCK_U" == "Hosting" ]] && S_PCK="Yes"
    local S_IPA=$(jq_get "$TMP_DIR/ip_api.json" '.hosting')

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Server" \
        "$(fmt_bool "$S_I2L")" "$(fmt_bool "$S_API")" "$(fmt_bool "$S_REG")" "$(fmt_bool "$S_IPQ")" \
        "$(fmt_bool "$S_SCM")" "$(fmt_bool "$S_IPD")" "$(fmt_bool "$S_PCK")" "$(fmt_bool "$S_IPA")"

    local A_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_spammer')
    local A_API=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_abuser')
    local A_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_abuser')
    local A_PQS=$(jq_get "$TMP_DIR/ipqs.json" '.recent_abuse')
    local A_SCM=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_blacklisted_external')
    local A_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_known_abuser')

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Abuser" \
        "$(fmt_bool "$A_I2L")" "$(fmt_bool "$A_API")" "$(fmt_bool "$A_REG")" "$(fmt_bool "$A_PQS")" \
        "$(fmt_bool "$A_SCM")" "$(fmt_bool "$A_IPD")" "$(fmt_bool "No")" "$(fmt_bool "N/A")"

    local B_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_scanner')
    local B_API=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_crawler')
    local B_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_attacker')
    local B_PQS=$(jq_get "$TMP_DIR/ipqs.json" '.bot_status')
    local B_SCM=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_google')
    local B_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_threat')

    printf " ${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Robot" \
        "$(fmt_bool "$B_I2L")" "$(fmt_bool "$B_API")" "$(fmt_bool "$B_REG")" "$(fmt_bool "$B_PQS")" \
        "$(fmt_bool "$B_SCM")" "$(fmt_bool "$B_IPD")" "$(fmt_bool "No")" "$(fmt_bool "N/A")"

    # --- V. Streaming, AI & Web Accessibility ---
    if ((IS_LOCAL_IP == 1)); then
        print_section "V. Streaming, AI & Web Accessibility (${IPV_LABEL})"

        IFS='|' read -r s_tt r_tt t_tt <<<"$(cat "$TMP_DIR/srv_tiktok" 2>/dev/null || true)"
        IFS='|' read -r s_dp r_dp t_dp <<<"$(cat "$TMP_DIR/srv_disney" 2>/dev/null || true)"
        IFS='|' read -r s_nf r_nf t_nf <<<"$(cat "$TMP_DIR/srv_netflix" 2>/dev/null || true)"
        IFS='|' read -r s_yt r_yt t_yt <<<"$(cat "$TMP_DIR/srv_youtube" 2>/dev/null || true)"
        IFS='|' read -r s_sp r_sp t_sp <<<"$(cat "$TMP_DIR/srv_spotify" 2>/dev/null || true)"
        IFS='|' read -r s_tw r_tw t_tw <<<"$(cat "$TMP_DIR/srv_twitch" 2>/dev/null || true)"

        printf " ${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "Streaming:" "TikTok" "Disney+" "Netflix" "YouTube" "Spotify" "Twitch"
        printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Status:" \
            "$(fmt_srv_status "$s_tt")" "$(fmt_srv_status "$s_dp")" "$(fmt_srv_status "$s_nf")" \
            "$(fmt_srv_status "$s_yt")" "$(fmt_srv_status "$s_sp")" "$(fmt_srv_status "$s_tw")"
        printf " ${C_CYAN}%-11s${C_RESET} %-9s  %-9s  %-9s  %-9s  %-9s  %-9s\n" "Region:" \
            "[${r_tt:-N/A}]" "[${r_dp:-N/A}]" "[${r_nf:-N/A}]" "[${r_yt:-N/A}]" "[${r_sp:-N/A}]" "[${r_tw:-N/A}]"
        printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Type:" \
            "$(fmt_srv_type "$t_tt")" "$(fmt_srv_type "$t_dp")" "$(fmt_srv_type "$t_nf")" \
            "$(fmt_srv_type "$t_yt")" "$(fmt_srv_type "$t_sp")" "$(fmt_srv_type "$t_tw")"

        printf '\n'
        IFS='|' read -r s_oa r_oa t_oa <<<"$(cat "$TMP_DIR/ai_chatgpt" 2>/dev/null || true)"
        IFS='|' read -r s_gm r_gm t_gm <<<"$(cat "$TMP_DIR/ai_gemini" 2>/dev/null || true)"
        IFS='|' read -r s_cl r_cl t_cl <<<"$(cat "$TMP_DIR/ai_claude" 2>/dev/null || true)"
        IFS='|' read -r s_cp r_cp t_cp <<<"$(cat "$TMP_DIR/ai_copilot" 2>/dev/null || true)"
        IFS='|' read -r s_cf r_cf t_cf <<<"$(cat "$TMP_DIR/cdn_cf" 2>/dev/null || true)"
        IFS='|' read -r s_gs r_gs t_gs <<<"$(cat "$TMP_DIR/cdn_google" 2>/dev/null || true)"

        printf " ${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "AI / Web:" "ChatGPT" "Gemini" "Claude" "xAI Grok" "Cloudflare" "Google"
        printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Status:" \
            "$(fmt_srv_status "$s_oa")" "$(fmt_srv_status "$s_gm")" "$(fmt_srv_status "$s_cl")" \
            "$(fmt_srv_status "$s_cp")" "$(fmt_srv_status "$s_cf")" "$(fmt_srv_status "$s_gs")"
        printf " ${C_CYAN}%-11s${C_RESET} %-9s  %-9s  %-9s  %-9s  %-9s  %-9s\n" "Region:" \
            "[${r_oa:-N/A}]" "[${r_gm:-N/A}]" "[${r_cl:-N/A}]" "[${r_cp:-N/A}]" "[${r_cf:-N/A}]" "[${r_gs:-N/A}]"
        printf " ${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Detail:" \
            "$(fmt_srv_type "$t_oa")" "$(fmt_srv_type "$t_gm")" "$(fmt_srv_type "$t_cl")" \
            "$(fmt_srv_type "$t_cp")" "$(fmt_srv_type "$t_cf")" "$(fmt_srv_type "$t_gs")"

        # --- VI. CDN Anycast Edge Nodes ---
        print_section "VI. CDN Edge Nodes (${IPV_LABEL})"
        IFS='|' read -r cf_cc cf_node <<<"$(cat "$TMP_DIR/cdn_cloudflare" 2>/dev/null || echo "-|-")"
        IFS='|' read -r yt_cc yt_node <<<"$(cat "$TMP_DIR/cdn_youtube" 2>/dev/null || echo "-|-")"
        IFS='|' read -r nf_cc nf_node <<<"$(cat "$TMP_DIR/cdn_netflix" 2>/dev/null || echo "-|-")"
        IFS='|' read -r fs_cc fs_node <<<"$(cat "$TMP_DIR/cdn_fastly" 2>/dev/null || echo "-|-")"

        printf " ${C_CYAN}%-18s${C_RESET}[%s] %s\n" "Cloudflare Edge:" "${cf_cc:--}" "${cf_node:--}"
        printf " ${C_CYAN}%-18s${C_RESET}[%s] %s\n" "YouTube (GGC):" "${yt_cc:--}" "${yt_node:--}"
        printf " ${C_CYAN}%-18s${C_RESET}[%s] %s\n" "Netflix (OCA):" "${nf_cc:--}" "${nf_node:--}"
        printf " ${C_CYAN}%-18s${C_RESET}[%s] %s\n" "Fastly POP:" "${fs_cc:--}" "${fs_node:--}"
    fi

    # --- VII. Email Connectivity & DNSBL ---
    print_section "VII. Email Connectivity & DNSBL (${IPV_LABEL})"
    if ((IS_LOCAL_IP == 1)); then
        local p25_st
        p25_st=$(cat "$TMP_DIR/p25_local" 2>/dev/null || true)
        if [[ "$p25_st" == "Open" ]]; then
            printf " ${C_CYAN}%-18s${C_RESET}${C_GREEN}${C_BOLD}Open (Outbound SMTP Allowed)${C_RESET}\n" "Local Port 25:"
        else
            printf " ${C_CYAN}%-18s${C_RESET}${C_RED}${C_BOLD}Blocked by ISP/Hosting${C_RESET}\n" "Local Port 25:"
        fi

        local m_line=""
        for m_name in Gmail Outlook Yahoo Apple Proton Yandex Mail.ru Zoho; do
            local mst
            mst=$(cat "$TMP_DIR/mail_${m_name}" 2>/dev/null || true)
            case "$mst" in
                Yes)    m_line+="${m_name}:${C_GREEN}✔${C_RESET}  " ;;
                NoIPv6) m_line+="${m_name}:${C_DIM}-${C_RESET}  " ;;
                *)      m_line+="${m_name}:${C_RED}✘${C_RESET}  " ;;
            esac
        done
        printf " ${C_CYAN}%-18s${C_RESET}%b\n" "MX Reachability:" "$m_line"
    fi

    local listed_files=("$TMP_DIR/rbl/"*)
    local listed_count=0
    local listed_names=()
    if [[ -e "${listed_files[0]}" ]]; then
        listed_count=${#listed_files[@]}
        for f in "${listed_files[@]}"; do
            listed_names+=("$(<"$f")")
        done
    fi
    local clean_count=$((RBL_TOTAL - listed_count))

    if ((listed_count == 0)); then
        printf " ${C_CYAN}%-18s${C_RESET}${C_GREEN}${C_BOLD}Clean (${clean_count}/${RBL_TOTAL}) · Blacklisted: 0${C_RESET}\n" "DNSBL Status:"
    else
        printf " ${C_CYAN}%-18s${C_RESET}${C_RED}${C_BOLD}Listed in ${listed_count}/${RBL_TOTAL}: ${listed_names[*]}${C_RESET}\n" "DNSBL Status:"
    fi
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
check_deps

# Pre-fetch MaxMind Demo Token in background
(
    mm_page=$(curl -sLm 4 -A "$UA_BROWSER" -c "$BASE_TMP/mm_cookies" "https://www.maxmind.com/en/geoip-web-services-demo" 2>/dev/null || true)
    if [[ "$mm_page" =~ value=\"([0-9a-f]+)\"\ name=\"csrf_token\" ]]; then
        csrf="${BASH_REMATCH[1]}"
        curl -sLm 4 -A "$UA_BROWSER" -X POST -b "$BASE_TMP/mm_cookies" -H "X-CSRF-Token: $csrf" \
            "https://www.maxmind.com/en/geoip2/demo/token" 2>/dev/null | jq -r '.token // empty' > "$BASE_TMP/mm_token" 2>/dev/null || true
    fi
) &
wait_with_spinner "Initializing session"

if [[ -n "$CUSTOM_IP" ]]; then
    if [[ "$CUSTOM_IP" == *":"* ]]; then
        run_check_for_stack "-6" "IPv6" "$CUSTOM_IP" 0
    else
        run_check_for_stack "-4" "IPv4" "$CUSTOM_IP" 0
    fi
else
    IPV4_ADDR=""
    IPV6_ADDR=""
    if [[ "$STACK_MODE" == "dual" || "$STACK_MODE" == "4" ]]; then
        IPV4_ADDR=$(curl -s4m 4 "https://ipv4.icanhazip.com" 2>/dev/null || curl -s4m 4 "https://api.ipify.org" 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ "$STACK_MODE" == "dual" || "$STACK_MODE" == "6" ]]; then
        IPV6_ADDR=$(curl -s6m 4 "https://ipv6.icanhazip.com" 2>/dev/null || curl -s6m 4 "https://api6.ipify.org" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -z "$IPV4_ADDR" && -z "$IPV6_ADDR" ]]; then
        printf '%s[✗]%s Could not detect public IPv4 or IPv6 address.\n' "$C_RED" "$C_RESET" >&2
        exit 1
    fi

    [[ -n "$IPV4_ADDR" ]] && run_check_for_stack "-4" "IPv4" "$IPV4_ADDR" 1
    [[ -n "$IPV6_ADDR" ]] && run_check_for_stack "-6" "IPv6" "$IPV6_ADDR" 1
fi

printf '\n'
