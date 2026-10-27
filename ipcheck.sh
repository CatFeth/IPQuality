#!/usr/bin/env bash
# ==============================================================================
# IPQuality | Dual-Stack (IPv4 + IPv6) Diagnostics
# ==============================================================================

export LC_ALL=C
REPORT_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

STACK_MODE="dual"
CUSTOM_IP=""

while getopts "46i:h" opt; do
    case "$opt" in
        4) STACK_MODE="4" ;;
        6) STACK_MODE="6" ;;
        i) CUSTOM_IP="$OPTARG" ;;
        h)
            echo "Usage: bash ipcheck.sh [-4|-6] [-i target_ip]"
            exit 0
            ;;
    esac
done

# --- ANSI Colors ---
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
C_RED="\033[31m"; C_BLUE="\033[34m"; C_PURPLE="\033[35m"

BG_GREEN="\033[42;30m"; BG_YELLOW="\033[43;30m"
BG_RED="\033[41;97m"; BG_GRAY="\033[100;37m"

BASE_TMP=$(mktemp -d -t ipq.XXXXXX)
trap 'rm -rf "$BASE_TMP"' EXIT

UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

check_deps() {
    local missing=()
    for cmd in curl jq awk sed tr head cut; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v dig &>/dev/null && ! command -v host &>/dev/null; then
        missing+=("dnsutils")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        if [ "$EUID" -eq 0 ]; then
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
            echo -e "${C_RED}[!] Missing dependencies: ${missing[*]}. Run as root or install manually.${C_RESET}"
            exit 1
        fi
    fi
}

# Безопасное извлечение из JSON (не превращает boolean false в N/A!)
jq_get() {
    local file="$1"; local query="$2"
    [ ! -s "$file" ] && { echo "N/A"; return; }
    local res=$(jq -r "(${query}) | if . == null then \"N/A\" else tostring end" "$file" 2>/dev/null)
    [ -z "$res" ] && res="N/A"
    echo "$res"
}

# --- UI Helpers (Compact 64-col Grid: 8-char badges + 1 space = 9 chars/col) ---
format_type_badge() {
    local val=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$val" in
        *hosting*|*datacenter*|*dch*|*transit*|*vpn*)
            printf "${BG_RED} %-6s ${C_RESET}" "Host" ;;
        *cdn*|*content*)
            printf "${BG_RED} %-6s ${C_RESET}" "CDN" ;;
        *spider*|*ses*|*crawler*)
            printf "${BG_RED} %-6s ${C_RESET}" "Spider" ;;
        *line*|*fixed*)
            printf "${BG_GREEN} %-6s ${C_RESET}" "Line" ;;
        *isp*|*residential*|*home*)
            printf "${BG_GREEN} %-6s ${C_RESET}" "ISP" ;;
        *mobile*|*mob*|*cellular*|*wireless*)
            printf "${BG_GREEN} %-6s ${C_RESET}" "Mobile" ;;
        *business*|*com*|*commercial*|*corporate*|*org*|*bank*)
            printf "${BG_YELLOW} %-6s ${C_RESET}" "Biz" ;;
        *edu*|*university*|*school*)
            printf "${BG_YELLOW} %-6s ${C_RESET}" "Edu" ;;
        *gov*|*mil*)
            printf "${BG_YELLOW} %-6s ${C_RESET}" "Gov" ;;
        *)
            printf "${BG_GRAY} %-6s ${C_RESET}" "N/A" ;;
    esac
}

# Шкала Levels имеет длину ровно 36 символов (13 зел + 11 желт + 12 красн)
draw_score_bar() {
    local label="$1"; local score="$2"; local disp_val="$3"; local level_txt="$4"
    local bar_len=$(awk -v s="$score" 'BEGIN { len=int(s * 0.36); if(len<1) len=1; if(len>36) len=36; print len }')
    local bar_color="$BG_GREEN"; local txt_color="$C_GREEN"

    case "$level_txt" in
        High|VeryHigh|DoS|Risky|HighRisk)
            bar_color="$BG_RED"; txt_color="$C_RED" ;;
        Medium|Elevated|Suspicious)
            bar_color="$BG_YELLOW"; txt_color="$C_YELLOW" ;;
        *)
            bar_color="$BG_GREEN"; txt_color="$C_GREEN" ;;
    esac

    local spaces=$(printf "%${bar_len}s" "")
    printf "${C_CYAN}%-13s${C_RESET}${bar_color}${spaces}${C_RESET} ${txt_color}${C_BOLD}%s|%s${C_RESET}\n" "${label}:" "$disp_val" "$level_txt"
}

# Строго 7 символов на колонку в Risk Factors (8 + 8*7 = 64 символа)
fmt_bool() {
    case "$1" in
        true|Yes|yes|1) printf "${C_RED}${C_BOLD}%-7s${C_RESET}" "Yes" ;;
        false|No|no|0)  printf "${C_GREEN}%-7s${C_RESET}" "No" ;;
        *)              printf "${C_DIM}%-7s${C_RESET}" "N/A" ;;
    esac
}

fmt_reg() {
    if [ -n "$1" ] && [ "$1" != "null" ] && [ "$1" != "N/A" ] && [ ${#1} -eq 2 ]; then
        printf "${C_GREEN}%-7s${C_RESET}" "[${1}]"
    else
        printf "${C_DIM}%-7s${C_RESET}" "N/A"
    fi
}

fmt_srv_status() {
    case "$1" in
        Yes)      printf "${BG_GREEN} %-6s ${C_RESET}" "Yes" ;;
        NoPrem.)  printf "${BG_RED} %-6s ${C_RESET}" "NoPrem" ;;
        OrigOnly) printf "${BG_YELLOW} %-6s ${C_RESET}" "Orig." ;;
        NoIPv6)   printf "${BG_GRAY} %-6s ${C_RESET}" "NoIPv6" ;;
        Clean*)   printf "${BG_GREEN} %-6s ${C_RESET}" "Clean" ;;
        Captcha*) printf "${BG_YELLOW} %-6s ${C_RESET}" "Captch" ;;
        Block|*)  printf "${BG_RED} %-6s ${C_RESET}" "Block" ;;
    esac
}

fmt_srv_type() {
    case "$1" in
        Native)       printf "${BG_GREEN} %-6s ${C_RESET}" "Native" ;;
        GoogleDB)     printf "${BG_YELLOW} %-6s ${C_RESET}" "GoogDB" ;;
        GeoDiff)      printf "${BG_YELLOW} %-6s ${C_RESET}" "GeoDif" ;;
        ViaDNS|Proxy) printf "${BG_YELLOW} %-6s ${C_RESET}" "ViaDNS" ;;
        200*)         printf "${BG_GREEN} %-6s ${C_RESET}" "200 OK" ;;
        429*)         printf "${BG_YELLOW} %-6s ${C_RESET}" "HTTP429" ;;
        *)            printf " %-6s " "" ;;
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

    # --- 1. Fetch All 9 IP Databases in Parallel ---
    curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?lang=en" > "$TMP_DIR/maxmind.json" &

    (
        curl -sLm 6 -A "$UA_BROWSER" "https://ipinfo.io/widget/demo/${TARGET_IP}" > "$TMP_DIR/ipinfo_widget.json"
        if ! jq -e '.data' "$TMP_DIR/ipinfo_widget.json" &>/dev/null; then
            curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.io/${TARGET_IP}/json" > "$TMP_DIR/ipinfo_direct.json"
        fi
    ) &

    (
        local reg_key="sb69ksjcajfs4c"
        local reg_html=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" "https://ipregistry.co" 2>/dev/null)
        if [[ "$reg_html" =~ apiKey=\"([a-zA-Z0-9]+)\" ]]; then
            reg_key="${BASH_REMATCH[1]}"
        fi
        curl -sL $IPV_MODE --compressed -m 6 -A "$UA_BROWSER" \
            -H "origin: https://ipregistry.co" -H "referer: https://ipregistry.co/" \
            "https://api.ipregistry.co/${TARGET_IP}?hostname=true&key=${reg_key}" > "$TMP_DIR/ipregistry.json"
    ) &

    (
        curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?db=ipapi" > "$TMP_DIR/ipapi_is.json"
        if ! jq -e '.asn' "$TMP_DIR/ipapi_is.json" &>/dev/null; then
            curl -sLm 6 -A "$UA_BROWSER" "https://api.ipapi.is/?q=${TARGET_IP}" > "$TMP_DIR/ipapi_is.json"
        fi
    ) &

    (
        curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?db=scamalytics" > "$TMP_DIR/scamalytics.json"
        if ! jq -e '.scamalytics' "$TMP_DIR/scamalytics.json" &>/dev/null; then
            curl -sLm 6 -A "$UA_BROWSER" "https://scamalytics.com/ip/${TARGET_IP}" > "$TMP_DIR/scamalytics.html"
        fi
    ) &

    curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?db=ip2location" > "$TMP_DIR/ip2location.json" &
    curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?db=abuseipdb" > "$TMP_DIR/abuseipdb.json" &
    curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?db=ipdata" > "$TMP_DIR/ipdata.json" &
    curl -sL $IPV_MODE -m 6 "https://ipinfo.check.place/${TARGET_IP}?db=ipqualityscore" > "$TMP_DIR/ipqs.json" &

    curl -sLm 6 -A "$UA_BROWSER" "https://proxycheck.io/v2/${TARGET_IP}?vpn=1&asn=1&risk=1" > "$TMP_DIR/proxycheck.json" &
    curl -sLm 6 -A "$UA_BROWSER" "http://ip-api.com/json/${TARGET_IP}?fields=status,country,countryCode,regionName,city,zip,lat,lon,timezone,isp,org,as,mobile,proxy,hosting" > "$TMP_DIR/ip_api.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://ipwho.is/${TARGET_IP}" > "$TMP_DIR/ipwhois.json" &

    (
        if command -v dig &>/dev/null; then
            dig +short -x "$TARGET_IP" | head -n1 | sed 's/\.$//' > "$TMP_DIR/ptr.txt"
        elif command -v host &>/dev/null; then
            host "$TARGET_IP" | awk '/domain name pointer/ {print $5}' | sed 's/\.$//' | head -n1 > "$TMP_DIR/ptr.txt"
        fi
    ) &

    wait

    # --- 2. Parse Basic Information ---
    local ASN=$(jq -r '.ASN.AutonomousSystemNumber // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$ASN" = "null" ] && ASN=""
    [ -n "$ASN" ] && ASN="AS${ASN}"
    [ -z "$ASN" ] && ASN=$(jq -r '.data.asn.asn // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    [ -z "$ASN" ] && ASN=$(jq -r --arg ip "$TARGET_IP" '.[$ip].asn // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null)
    [ -z "$ASN" ] && ASN=$(jq -r '.as // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null | awk '{print $1}')

    local ORG=$(jq -r '.ASN.AutonomousSystemOrganization // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$ORG" = "null" ] && ORG=""
    [ -z "$ORG" ] && ORG=$(jq -r '.data.asn.name // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    [ -z "$ORG" ] && ORG=$(jq -r --arg ip "$TARGET_IP" '.[$ip].provider // .[$ip].organisation // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null)
    [ -z "$ORG" ] && ORG=$(jq -r '.org // .isp // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null)

    local CITY=$(jq -r '.City.Name // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$CITY" = "null" ] && CITY=""
    local POSTAL=$(jq -r '.City.PostalCode // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$POSTAL" = "null" ] && POSTAL=""
    [ -z "$CITY" ] && CITY=$(jq -r '.data.city // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    [ -z "$POSTAL" ] && POSTAL=$(jq -r '.data.postal // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    [ -z "$CITY" ] && CITY=$(jq -r '.city // "N/A"' "$TMP_DIR/ip_api.json" 2>/dev/null)
    [ -z "$POSTAL" ] && POSTAL=$(jq -r '.zip // empty' "$TMP_DIR/ip_api.json" 2>/dev/null)

    local COUNTRY_CODE=$(jq -r '.Country.IsoCode // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$COUNTRY_CODE" = "null" ] && COUNTRY_CODE=""
    [ -z "$COUNTRY_CODE" ] && COUNTRY_CODE=$(jq -r '.countryCode // empty' "$TMP_DIR/ip_api.json" 2>/dev/null)
    [ -z "$COUNTRY_CODE" ] && COUNTRY_CODE=$(jq -r '.data.country // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    [ -z "$COUNTRY_CODE" ] && COUNTRY_CODE=$(jq -r --arg ip "$TARGET_IP" '.[$ip].isocode // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null)

    local COUNTRY_NAME=$(jq -r '.Country.Name // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$COUNTRY_NAME" = "null" ] && COUNTRY_NAME=""
    [ -z "$COUNTRY_NAME" ] && COUNTRY_NAME=$(jq -r '.country // empty' "$TMP_DIR/ip_api.json" 2>/dev/null)
    [ -z "$COUNTRY_NAME" ] && COUNTRY_NAME=$(jq -r --arg ip "$TARGET_IP" '.[$ip].country // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null)

    local REG_COUNTRY=$(jq -r '.Country.RegisteredCountry.IsoCode // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$REG_COUNTRY" = "null" ] && REG_COUNTRY=""
    [ -z "$REG_COUNTRY" ] && REG_COUNTRY=$(jq -r '.data.abuse.country // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    [ -z "$REG_COUNTRY" ] && REG_COUNTRY=$(jq -r '.asn.country // empty' "$TMP_DIR/ipapi_is.json" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [ -z "$REG_COUNTRY" ] && REG_COUNTRY="$COUNTRY_CODE"

    local TIMEZONE=$(jq -r '.City.Location.TimeZone // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    [ "$TIMEZONE" = "null" ] && TIMEZONE=""
    [ -z "$TIMEZONE" ] && TIMEZONE=$(jq -r '.timezone // empty' "$TMP_DIR/ip_api.json" 2>/dev/null)
    [ -z "$TIMEZONE" ] && TIMEZONE=$(jq -r '.data.timezone // "N/A"' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)

    local LAT_LON=""
    local m_lat=$(jq -r '.City.Latitude // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    local m_lon=$(jq -r '.City.Longitude // empty' "$TMP_DIR/maxmind.json" 2>/dev/null)
    if [ -n "$m_lat" ] && [ "$m_lat" != "null" ]; then
        LAT_LON="${m_lat},${m_lon}"
    else
        LAT_LON=$(jq -r '.data.loc // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null)
    fi
    if [ -z "$LAT_LON" ] || [ "$LAT_LON" = "null" ]; then
        local lat=$(jq -r '.lat // empty' "$TMP_DIR/ip_api.json" 2>/dev/null)
        local lon=$(jq -r '.lon // empty' "$TMP_DIR/ip_api.json" 2>/dev/null)
        [ -n "$lat" ] && [ -n "$lon" ] && LAT_LON="${lat},${lon}"
    fi
    if [ -z "$LAT_LON" ] || [ "$LAT_LON" = "null" ]; then
        local lat2=$(jq -r '.latitude // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null)
        local lon2=$(jq -r '.longitude // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null)
        [ -n "$lat2" ] && [ -n "$lon2" ] && LAT_LON="${lat2},${lon2}"
    fi

    local PTR_RECORD=$(cat "$TMP_DIR/ptr.txt" 2>/dev/null)
    [ -z "$PTR_RECORD" ] && PTR_RECORD="No PTR (Missing rDNS)"

    # --- 3. Parse IP Types Across 6 Databases ---
    local T_INF_U=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.asn.type')
    local T_INF_C=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.company.type')
    if [ "$T_INF_U" = "N/A" ]; then
        if echo "$ORG" | grep -qiE "host|cloud|server|vps|data|dedi|netcup|hetzner|ovh|digitalocean|linode|vultr|leaseweb|choopa|contabo|waicore|pq.hosting|aeza|melbicom"; then
            T_INF_U="hosting"; T_INF_C="hosting"
        else
            T_INF_U="isp"; T_INF_C="isp"
        fi
    fi

    local T_REG_U=$(jq_get "$TMP_DIR/ipregistry.json" '.connection.type')
    local T_REG_C=$(jq_get "$TMP_DIR/ipregistry.json" '.company.type')
    local T_API_U=$(jq_get "$TMP_DIR/ipapi_is.json" '.asn.type')
    local T_API_C=$(jq_get "$TMP_DIR/ipapi_is.json" '.company.type')
    local T_I2L_U=$(jq_get "$TMP_DIR/ip2location.json" '.usage_type')
    local T_I2L_C=$(jq_get "$TMP_DIR/ip2location.json" '.as_info.as_usage_type')
    local T_ABU_U=$(jq_get "$TMP_DIR/abuseipdb.json" '.data.usageType')
    local T_PCK_U=$(jq -r --arg ip "$TARGET_IP" '.[$ip].type // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null)

    # --- 4. Parse Risk Scores ---
    local I2L_SCORE=$(jq -r '.fraud_score // empty' "$TMP_DIR/ip2location.json" 2>/dev/null)
    [ "$I2L_SCORE" = "null" ] && I2L_SCORE=""

    local SCAM_SCORE=$(jq -r '.scamalytics.scamalytics_score // empty' "$TMP_DIR/scamalytics.json" 2>/dev/null)
    [ "$SCAM_SCORE" = "null" ] && SCAM_SCORE=""
    if [ -z "$SCAM_SCORE" ] && [ -s "$TMP_DIR/scamalytics.html" ]; then
        SCAM_SCORE=$(grep -oE '"score":"[0-9]+"' "$TMP_DIR/scamalytics.html" 2>/dev/null | head -n1 | grep -oE '[0-9]+')
        [ -z "$SCAM_SCORE" ] && SCAM_SCORE=$(grep -i "Fraud Score:" "$TMP_DIR/scamalytics.html" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
    fi

    local IPAPI_RAW_SCORE=$(jq -r '.company.abuser_score // .asn.abuser_score // empty' "$TMP_DIR/ipapi_is.json" 2>/dev/null)
    [ "$IPAPI_RAW_SCORE" = "null" ] && IPAPI_RAW_SCORE=""
    local IPAPI_PCT=""; local IPAPI_LVL=""
    if [ -n "$IPAPI_RAW_SCORE" ]; then
        IPAPI_PCT=$(echo "$IPAPI_RAW_SCORE" | awk '{printf "%.2f", $1 * 100}')
        IPAPI_LVL=$(echo "$IPAPI_RAW_SCORE" | grep -oE '\([A-Za-z ]+\)' | tr -d '() ')
    fi

    local ABUSE_SCORE=$(jq -r '.data.abuseConfidenceScore // empty' "$TMP_DIR/abuseipdb.json" 2>/dev/null)
    [ "$ABUSE_SCORE" = "null" ] && ABUSE_SCORE=""

    local IPQS_SCORE=$(jq -r '.fraud_score // empty' "$TMP_DIR/ipqs.json" 2>/dev/null)
    [ "$IPQS_SCORE" = "null" ] && IPQS_SCORE=""

    local PCHECK_SCORE=$(jq -r --arg ip "$TARGET_IP" '.[$ip].risk // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null)
    [ "$PCHECK_SCORE" = "null" ] && PCHECK_SCORE=""

    # --- 5. Services, AI, CDN & Email (Strict $IPV_MODE) ---
    if [ "$IS_LOCAL_IP" -eq 1 ]; then
        (
            local yt_html=$(curl -sL $IPV_MODE -m 6 -A "$UA_BROWSER" "https://www.youtube.com/premium" 2>/dev/null)
            local gm_res=$(curl -sL $IPV_MODE -m 6 -A "$UA_BROWSER" -w "\nFINAL_URL:%{url_effective}" "https://gemini.google.com/app" 2>/dev/null)
            local gm_url=$(echo "$gm_res" | grep "^FINAL_URL:" | cut -d':' -f2-)

            local yt_gl=$(echo "$yt_html" | grep -oE '"GL":"[A-Z]{2}"|"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"|"countryCode":"[A-Z]{2}"' | head -n1 | cut -d'"' -f4)
            [ -z "$yt_gl" ] && yt_gl="$COUNTRY_CODE"

            local gemini_blocked=0
            if [[ "$gm_url" == *"/faq"* ]] || echo "$gm_res" | grep -qiE "isn't currently supported|not available in your country"; then
                gemini_blocked=1
            fi

            local yt_noprem=0
            if echo "$yt_html" | grep -qiE "YouTube Premium is not available in your country|недоступен в вашей стране|isn't available" || [ "$yt_gl" = "RU" ] || [ "$gemini_blocked" -eq 1 ]; then
                yt_noprem=1
                if [ "$gemini_blocked" -eq 1 ] && [ "$yt_gl" = "$COUNTRY_CODE" ] && [[ ! "$COUNTRY_CODE" =~ ^(RU|BY|CN|HK|IR|KP)$ ]]; then
                    yt_gl="RU"
                fi
            fi

            echo "$yt_gl" > "$TMP_DIR/google_gl"

            if [ "$yt_noprem" -eq 1 ]; then
                local tp="Native"; [ "$yt_gl" != "$COUNTRY_CODE" ] && tp="GoogleDB"
                echo "NoPrem.|${yt_gl}|${tp}" > "$TMP_DIR/srv_youtube"
            else
                local tp="Native"; [ "$yt_gl" != "$COUNTRY_CODE" ] && tp="GoogleDB"
                echo "Yes|${yt_gl}|${tp}" > "$TMP_DIR/srv_youtube"
            fi

            if [ "$gemini_blocked" -eq 1 ] || [[ "$yt_gl" =~ ^(RU|BY|CN|HK|KP|IR)$ ]]; then
                local tp="Native"; [ "$yt_gl" != "$COUNTRY_CODE" ] && tp="GoogleDB"
                echo "Block|${yt_gl}|${tp}" > "$TMP_DIR/ai_gemini"
            else
                local tp="Native"; [ "$yt_gl" != "$COUNTRY_CODE" ] && tp="GoogleDB"
                echo "Yes|${yt_gl}|${tp}" > "$TMP_DIR/ai_gemini"
            fi
        ) &

        (
            local tt_out=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" -w "\nCODE:%{http_code}" "https://www.tiktok.com/explore" 2>/dev/null)
            local tt_code=$(echo "$tt_out" | grep "^CODE:" | cut -d':' -f2)
            local tt_reg=$(echo "$tt_out" | grep -oE '"region":"[A-Z]{2}"' | head -n1 | cut -d'"' -f4)
            if [ "$tt_code" = "000" ] && [ "$IPV_MODE" = "-6" ]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_tiktok"
            elif [ -n "$tt_reg" ] && [[ ! "$tt_reg" =~ ^(RU|BY|CN|IR|KP|IN)$ ]]; then
                echo "Yes|${tt_reg}|Native" > "$TMP_DIR/srv_tiktok"
            else
                echo "Block|${tt_reg:-N/A}|N/A" > "$TMP_DIR/srv_tiktok"
            fi
        ) &

        (
            local nf_body=$(curl -sL $IPV_MODE -m 6 -A "$UA_BROWSER" -w "\nHTTP_CODE:%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null)
            local nf_code1=$(echo "$nf_body" | grep "^HTTP_CODE:" | cut -d':' -f2)
            local nf_reg=$(echo "$nf_body" | grep -oE '"requestCountry":\{"id":"[A-Z]{2}"' | head -n1 | cut -d'"' -f6)
            [ -z "$nf_reg" ] && nf_reg=$(echo "$nf_body" | grep -oE '"country":"[A-Z]{2}"' | head -n1 | cut -d'"' -f4)
            [ -z "$nf_reg" ] && nf_reg="$COUNTRY_CODE"

            if [ "$nf_code1" = "200" ]; then
                local tp="Native"; [ "$nf_reg" != "$COUNTRY_CODE" ] && tp="ViaDNS"
                echo "Yes|${nf_reg}|${tp}" > "$TMP_DIR/srv_netflix"
            else
                local nf_code2=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/80018499" 2>/dev/null)
                if [ "$nf_code2" = "200" ]; then
                    echo "OrigOnly|${nf_reg}|Proxy" > "$TMP_DIR/srv_netflix"
                else
                    echo "Block|${nf_reg:-N/A}|N/A" > "$TMP_DIR/srv_netflix"
                fi
            fi
        ) &

        (
            local dp_code=$(curl -sL $IPV_MODE -m 6 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.disneyplus.com/" 2>/dev/null)
            if [ "$dp_code" = "000" ] && [ "$IPV_MODE" = "-6" ]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_disney"
            elif [[ "$dp_code" =~ ^(200|301|302)$ ]] && [[ ! "$COUNTRY_CODE" =~ ^(RU|BY|CN|IR|CU)$ ]]; then
                echo "Yes|${COUNTRY_CODE}|Native" > "$TMP_DIR/srv_disney"
            else
                echo "Block|N/A|N/A" > "$TMP_DIR/srv_disney"
            fi
        ) &

        (
            local sp_code=$(curl -sL $IPV_MODE -m 6 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.spotify.com/api/signup/authenticate" 2>/dev/null)
            if [ "$sp_code" != "403" ] && [ "$sp_code" != "000" ] && [[ ! "$COUNTRY_CODE" =~ ^(RU|CN|IR|KP)$ ]]; then
                echo "Yes|${COUNTRY_CODE}|Native" > "$TMP_DIR/srv_spotify"
            else
                echo "Block|N/A|N/A" > "$TMP_DIR/srv_spotify"
            fi
        ) &

        (
            local tw_code=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://gql.twitch.tv/gql" 2>/dev/null)
            if [ "$tw_code" = "000" ] && [ "$IPV_MODE" = "-6" ]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_twitch"
            elif [ "$tw_code" != "000" ] && [ "$tw_code" != "403" ]; then
                echo "Yes|${COUNTRY_CODE}|Native" > "$TMP_DIR/srv_twitch"
            else
                echo "Block|N/A|N/A" > "$TMP_DIR/srv_twitch"
            fi
        ) &

        (
            local rd_code=$(curl -sL $IPV_MODE -m 6 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.reddit.com/r/popular.json" 2>/dev/null)
            if [ "$rd_code" = "200" ]; then
                echo "Yes|${COUNTRY_CODE}|Native" > "$TMP_DIR/srv_reddit"
            else
                echo "Block|N/A|N/A" > "$TMP_DIR/srv_reddit"
            fi
        ) &

        (
            local gpt_loc=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" "https://chatgpt.com/cdn-cgi/trace" 2>/dev/null | grep "^loc=" | cut -d'=' -f2)
            local gpt_api=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" "https://ios.chat.openai.com/public-api/mobile/server_status/v1" 2>/dev/null)
            if [ -n "$gpt_loc" ] && [[ ! "$gpt_loc" =~ ^(RU|BY|CN|IR|KP|SY|CU|HK)$ ]] && ! echo "$gpt_api" | grep -qi "unsupported_country"; then
                local tp="Native"; [ "$gpt_loc" != "$COUNTRY_CODE" ] && tp="ViaDNS"
                echo "Yes|${gpt_loc}|${tp}" > "$TMP_DIR/ai_chatgpt"
            else
                echo "Block|${gpt_loc:-N/A}|N/A" > "$TMP_DIR/ai_chatgpt"
            fi
        ) &

        (
            local cl_loc=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" "https://claude.ai/cdn-cgi/trace" 2>/dev/null | grep "^loc=" | cut -d'=' -f2)
            local cl_code=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://claude.ai/api/organizations" 2>/dev/null)
            if [ -n "$cl_loc" ] && [[ ! "$cl_loc" =~ ^(RU|BY|CN|IR|KP|SY|HK)$ ]] && [[ "$cl_code" =~ ^(200|401)$ ]]; then
                echo "Yes|${cl_loc}|Native" > "$TMP_DIR/ai_claude"
            else
                echo "Block|${cl_loc:-N/A}|N/A" > "$TMP_DIR/ai_claude"
            fi
        ) &

        (
            local jb_reg=$(curl -sL $IPV_MODE -m 5 -A "$UA_BROWSER" "https://data.services.jetbrains.com/geo" 2>/dev/null | jq -r '.code // empty' 2>/dev/null)
            if [ -n "$jb_reg" ] && [[ ! "$jb_reg" =~ ^(RU|BY|IR|KP|CU|SY)$ ]]; then
                local tp="Native"; [ "$jb_reg" != "$COUNTRY_CODE" ] && tp="GeoDiff"
                echo "Yes|${jb_reg}|${tp}" > "$TMP_DIR/ai_jetbrains"
            else
                echo "Block|${jb_reg:-N/A}|N/A" > "$TMP_DIR/ai_jetbrains"
            fi
        ) &

        (
            local gs_code=$(curl -s $IPV_MODE -m 6 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.google.com/search?q=test" 2>/dev/null)
            if [ "$gs_code" = "200" ]; then echo "Clean (200 OK)" > "$TMP_DIR/bot_google"
            elif [ "$gs_code" = "429" ] || [ "$gs_code" = "302" ]; then echo "Captcha (429)" > "$TMP_DIR/bot_google"
            else echo "Filtered ($gs_code)" > "$TMP_DIR/bot_google"; fi
        ) &

        (
            local cf_trace=$(curl -sL $IPV_MODE -m 5 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
            local cf_loc=$(echo "$cf_trace" | grep "^loc=" | cut -d'=' -f2)
            local cf_colo=$(echo "$cf_trace" | grep "^colo=" | cut -d'=' -f2)
            [ -n "$cf_loc" ] && echo "${cf_loc} (${cf_colo})" > "$TMP_DIR/cdn_cf" || echo "N/A" > "$TMP_DIR/cdn_cf"
        ) &

        (
            local yt_line=$(curl -sL $IPV_MODE -m 5 "https://redirector.googlevideo.com/report_mapping" 2>/dev/null | head -n1)
            local yt_node=$(echo "$yt_line" | awk -F'=> ' '{print $2}' | awk '{print $1}')
            local yt_iata=""
            if [[ "$yt_node" =~ ^[a-z]{3}[0-9]{2} ]]; then
                yt_iata=$(echo "$yt_node" | cut -c1-3 | tr '[:lower:]' '[:upper:]')
            elif [[ "$yt_node" =~ ^[a-z]{2}[a-z]{3}[a-z]?-[a-z]+ ]]; then
                yt_iata=$(echo "$yt_node" | cut -c3-5 | tr '[:lower:]' '[:upper:]')
            else
                yt_iata=$(echo "$yt_node" | cut -c1-3 | tr '[:lower:]' '[:upper:]')
            fi
            [ -n "$yt_iata" ] && echo "Edge (${yt_iata})" > "$TMP_DIR/cdn_yt" || echo "Direct" > "$TMP_DIR/cdn_yt"
        ) &
    fi

    # Email & DNSBL (Only for IPv4)
    if [ "$IPV_MODE" = "-4" ]; then
        if [ "$IS_LOCAL_IP" -eq 1 ]; then
            declare -A mx_hosts=( ["Gmail"]="gmail-smtp-in.l.google.com" ["Outlook"]="outlook-com.olc.protection.outlook.com" ["Yahoo"]="mta5.am0.yahoodns.net" ["Apple"]="mx01.mail.icloud.com" ["MailRU"]="mxs.mail.ru" ["Proton"]="mail.protonmail.ch" )
            for name in "${!mx_hosts[@]}"; do
                ( timeout 3 bash -c "cat < /dev/null > /dev/tcp/${mx_hosts[$name]}/25" 2>/dev/null && echo "OK" > "$TMP_DIR/mx_${name}" || echo "FAIL" > "$TMP_DIR/mx_${name}" ) &
            done
        fi
        local rev_ip=$(echo "$TARGET_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
        local rbls=( "zen.spamhaus.org" "bl.spamcop.net" "b.barracudacentral.org" "dnsbl.sorbs.net" "spam.dnsbl.sorbs.net" "dnsbl-1.uceprotect.net" "dnsbl-2.uceprotect.net" "dnsbl-3.uceprotect.net" "psbl.surriel.com" "db.wpbl.info" "dnsbl.dronebl.org" "all.s5h.net" "rbl.interserver.net" "bl.spameatingmonkey.net" "backscatter.spameatingmonkey.net" "bl.ipv6.spameatingmonkey.net" "dnsbl.spfbl.net" "bl.0spam.org" "rbl.0spam.org" "ips.backscatterer.org" "dyna.spamrats.com" "noptr.spamrats.com" "spam.spamrats.com" "bl.blocklist.de" "dnsbl.justspam.org" "rbl.efnetrbl.org" "tor.dan.me.uk" "torexit.dan.me.uk" "korea.services.net" "truncate.gbudb.net" )
        mkdir -p "$TMP_DIR/rbl"
        for rbl in "${rbls[@]}"; do
            (
                local res=""
                if command -v dig &>/dev/null; then res=$(dig +short +time=2 +tries=1 "${rev_ip}.${rbl}" A 2>/dev/null | grep -E '^127\.0\.0\.[0-9]+$')
                elif command -v host &>/dev/null; then res=$(host -W 2 "${rev_ip}.${rbl}" 2>/dev/null | grep -oE '127\.0\.0\.[0-9]+'); fi
                if [ -n "$res" ]; then
                    if [[ "$res" =~ ^127\.255\. ]]; then echo "CLEAN" > "$TMP_DIR/rbl/${rbl}"
                    elif [[ "$rbl" == *"uceprotect-2"* ]] || [[ "$rbl" == *"uceprotect-3"* ]] || [[ "$rbl" == *"sorbs"* ]]; then echo "MARKED" > "$TMP_DIR/rbl/${rbl}"
                    else echo "BLACKLISTED" > "$TMP_DIR/rbl/${rbl}"; fi
                else echo "CLEAN" > "$TMP_DIR/rbl/${rbl}"; fi
            ) &
        done
    fi
    wait

# --- 6. Render Output (Strict <= 64 chars width for Mobile & Desktop) ---
    echo ""
    echo -e " ${C_BOLD}${REPORT_TIME} | [${IPV_LABEL}]${C_RESET}"
    echo -e "${C_CYAN}################################################################${C_RESET}"
    echo -e "${C_BOLD}1. Basic Information ${C_DIM}(${IPV_LABEL} Multi-DB Aggregated)${C_RESET}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_PURPLE}${C_BOLD}%s${C_RESET}\n" "Target ${IPV_LABEL}:" "${TARGET_IP}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}%s${C_RESET}\n" "ASN:" "${ASN}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}%s${C_RESET}\n" "Organization:" "${ORG}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}%s${C_RESET}\n" "Location:" "${LAT_LON:-N/A}"
    [ -n "$LAT_LON" ] && printf "${C_CYAN}%-16s${C_RESET} \033[4;32mhttps://check.place/%s,12,en\033[0m\n" "Map:" "${LAT_LON}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}%s${C_RESET}\n" "City:" "${CITY}${POSTAL:+, $POSTAL}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}[%s] %s${C_RESET}\n" "Actual Region:" "${COUNTRY_CODE}" "${COUNTRY_NAME}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}[%s]${C_RESET}\n" "Registered Reg:" "${REG_COUNTRY}"
    printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}%s${C_RESET}\n" "Time Zone:" "${TIMEZONE}"
    printf "${C_CYAN}%-16s${C_RESET} %s\n" "PTR (rDNS):" "${PTR_RECORD}"

    local cf_cdn=$(cat "$TMP_DIR/cdn_cf" 2>/dev/null); local yt_cdn=$(cat "$TMP_DIR/cdn_yt" 2>/dev/null)
    [ -n "$cf_cdn" ] && printf "${C_CYAN}%-16s${C_RESET} ${C_GREEN}CF: %-9s YT: %s${C_RESET}\n" "CDN Edges:" "${cf_cdn}" "${yt_cdn:-N/A}"

    local geo_badge="${BG_GREEN} Geo-consistent ${C_RESET}"
    [ "$COUNTRY_CODE" != "$REG_COUNTRY" ] && geo_badge="${BG_YELLOW} Geo-discrepant (${REG_COUNTRY}->${COUNTRY_CODE}) ${C_RESET}"
    printf "${C_CYAN}%-16s${C_RESET} %b\n" "IP Type:" "$geo_badge"

    # === 2. IP TYPE (9-char label + 6 * 9-char cols = 63 chars) ===
    echo -e "${C_BOLD}2. IP Type${C_RESET}"
    printf "${C_CYAN}%-9s%-9s%-9s%-9s%-9s%-9s%-9s${C_RESET}\n" "DB:" "IPinfo" "ipreg." "ipapi" "IP2Loc" "AbuseIP" "ProxyCk"
    printf "${C_CYAN}%-9s${C_RESET}" "Usage:"
    format_type_badge "$T_INF_U"; printf " "
    format_type_badge "$T_REG_U"; printf " "
    format_type_badge "$T_API_U"; printf " "
    format_type_badge "$T_I2L_U"; printf " "
    format_type_badge "$T_ABU_U"; printf " "
    format_type_badge "$T_PCK_U"; echo ""

    printf "${C_CYAN}%-9s${C_RESET}" "Company:"
    format_type_badge "$T_INF_C"; printf " "
    format_type_badge "$T_REG_C"; printf " "
    format_type_badge "$T_API_C"; printf " "
    format_type_badge "$T_I2L_C"; printf " "
    printf "%-9s" ""
    format_type_badge "$T_PCK_U"; echo ""

    # === 3. RISK SCORE (13-char label + 36-char scale = 49 chars + text) ===
    echo -e "${C_BOLD}3. Risk Score${C_RESET}"
    printf "${C_CYAN}%-13s${C_RESET}${BG_GREEN} VeryLow  Low${BG_YELLOW}   Medium  ${BG_RED} High  VHigh${C_RESET}\n" "Levels:"
    if [ -n "$I2L_SCORE" ]; then
        local i2l_lvl="Low"; [ "$I2L_SCORE" -ge 33 ] && i2l_lvl="Medium"; [ "$I2L_SCORE" -ge 66 ] && i2l_lvl="High"
        draw_score_bar "IP2Location" "$I2L_SCORE" "$I2L_SCORE" "$i2l_lvl"
    fi
    if [ -n "$SCAM_SCORE" ]; then
        local scam_lvl="Low"; [ "$SCAM_SCORE" -ge 20 ] && scam_lvl="Medium"; [ "$SCAM_SCORE" -ge 60 ] && scam_lvl="High"; [ "$SCAM_SCORE" -ge 90 ] && scam_lvl="VeryHigh"
        draw_score_bar "Scamalytics" "$SCAM_SCORE" "$SCAM_SCORE" "$scam_lvl"
    fi
    if [ -n "$IPAPI_PCT" ]; then
        local scaled_ipapi=$(awk -v p="$IPAPI_PCT" 'BEGIN { if(p>=3) s=68+(p-3)*3; else if(p>=0.85) s=35+(p-0.85)*15; else s=p*35; if(s>100) s=100; print s }')
        draw_score_bar "ipapi" "$scaled_ipapi" "${IPAPI_PCT}%" "${IPAPI_LVL:-Low}"
    fi
    if [ -n "$ABUSE_SCORE" ]; then
        local abu_lvl="Low"; [ "$ABUSE_SCORE" -ge 25 ] && abu_lvl="High"; [ "$ABUSE_SCORE" -ge 75 ] && abu_lvl="DoS"
        draw_score_bar "AbuseIPDB" "$ABUSE_SCORE" "$ABUSE_SCORE" "$abu_lvl"
    fi
    if [ -n "$IPQS_SCORE" ]; then
        local ipqs_lvl="Low"; [ "$IPQS_SCORE" -ge 75 ] && ipqs_lvl="Suspicious"; [ "$IPQS_SCORE" -ge 85 ] && ipqs_lvl="Risky"; [ "$IPQS_SCORE" -ge 90 ] && ipqs_lvl="HighRisk"
        draw_score_bar "IPQS" "$IPQS_SCORE" "$IPQS_SCORE" "$ipqs_lvl"
    fi
    if [ -n "$PCHECK_SCORE" ]; then
        local pc_lvl="Low"; [ "$PCHECK_SCORE" -ge 33 ] && pc_lvl="Medium"; [ "$PCHECK_SCORE" -ge 66 ] && pc_lvl="High"
        draw_score_bar "ProxyCheck" "$PCHECK_SCORE" "${PCHECK_SCORE}%" "$pc_lvl"
    fi

    # === 4. RISK FACTORS (8-char label + 8 * 7-char cols = 64 chars) ===
    echo -e "${C_BOLD}4. Risk Factors${C_RESET}"
    printf "${C_CYAN}%-8s%-7s%-7s%-7s%-7s%-7s%-7s%-7s%-7s${C_RESET}\n" "DB:" "IP2Loc" "ipapi" "ipreg" "IPQS" "Scam." "ipdata" "IPinfo" "PrxCk"

    # 1. IP2Location Factors
    local i2l_cc=$(jq_get "$TMP_DIR/ip2location.json" '.country_code')
    local i2l_p0=$(jq_get "$TMP_DIR/ip2location.json" '.is_proxy')
    local i2l_p1=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_public_proxy')
    local i2l_p2=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_web_proxy')
    local i2l_prx="N/A"
    [[ "$i2l_p0" == "false" && "$i2l_p1" == "false" && "$i2l_p2" == "false" ]] && i2l_prx="false"
    [[ "$i2l_p0" == "true" || "$i2l_p1" == "true" || "$i2l_p2" == "true" ]] && i2l_prx="true"
    local i2l_tor=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_tor')
    local i2l_vpn=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_vpn')
    local i2l_srv=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_data_center')
    local i2l_abu=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_spammer')
    local i2l_b1=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_web_crawler')
    local i2l_b2=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_scanner')
    local i2l_b3=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_botnet')
    local i2l_bot="N/A"
    [[ "$i2l_b1" == "false" && "$i2l_b2" == "false" && "$i2l_b3" == "false" ]] && i2l_bot="false"
    [[ "$i2l_b1" == "true" || "$i2l_b2" == "true" || "$i2l_b3" == "true" ]] && i2l_bot="true"

    # 2. ipapi Factors
    local ipa_cc=$(jq_get "$TMP_DIR/ipapi_is.json" '.location.country_code')
    local ipa_prx=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_proxy')
    local ipa_tor=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_tor')
    local ipa_vpn=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_vpn')
    local ipa_srv=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_datacenter')
    local ipa_abu=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_abuser')
    local ipa_bot=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_crawler')

    # 3. ipregistry Factors
    local reg_cc=$(jq_get "$TMP_DIR/ipregistry.json" '.location.country.code')
    local reg_prx=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_proxy')
    local reg_t1=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_tor')
    local reg_t2=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_tor_exit')
    local reg_tor="N/A"
    [[ "$reg_t1" == "false" && "$reg_t2" == "false" ]] && reg_tor="false"
    [[ "$reg_t1" == "true" || "$reg_t2" == "true" ]] && reg_tor="true"
    local reg_vpn=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_vpn')
    local reg_srv=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_cloud_provider')
    local reg_abu=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_abuser')

    # 4. IPQS Factors
    local pqs_cc=$(jq_get "$TMP_DIR/ipqs.json" '.country_code')
    local pqs_prx=$(jq_get "$TMP_DIR/ipqs.json" '.proxy')
    local pqs_tor=$(jq_get "$TMP_DIR/ipqs.json" '.tor')
    local pqs_vpn=$(jq_get "$TMP_DIR/ipqs.json" '.vpn')
    local pqs_abu=$(jq_get "$TMP_DIR/ipqs.json" '.recent_abuse')
    local pqs_bot=$(jq_get "$TMP_DIR/ipqs.json" '.bot_status')

    # 5. Scamalytics Factors
    local sc_cc=$(jq_get "$TMP_DIR/scamalytics.json" '.external_datasources.maxmind_geolite2.ip_country_code')
    local sc_prx=$(jq_get "$TMP_DIR/scamalytics.json" '.external_datasources.firehol.is_proxy')
    local sc_tor=$(jq_get "$TMP_DIR/scamalytics.json" '.external_datasources.x4bnet.is_tor')
    local sc_vpn=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_vpn')
    local sc_srv=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.scamalytics_proxy.is_datacenter')
    local sc_abu=$(jq_get "$TMP_DIR/scamalytics.json" '.scamalytics.is_blacklisted_external')
    local sc_bot=$(jq_get "$TMP_DIR/scamalytics.json" '.external_datasources.x4bnet.is_blacklisted_spambot')
    if [ "$sc_vpn" = "N/A" ] && [ -s "$TMP_DIR/scamalytics.html" ]; then
        sc_cc="$COUNTRY_CODE"
        sc_vpn=$(grep -A3 -i "Anonymizing VPN" "$TMP_DIR/scamalytics.html" | grep -oE ">Yes<|>No<" | tr -d '<>' | head -n1)
        sc_tor=$(grep -A3 -i "Tor Exit Node" "$TMP_DIR/scamalytics.html" | grep -oE ">Yes<|>No<" | tr -d '<>' | head -n1)
        sc_srv=$(grep -A3 -i ">Server<" "$TMP_DIR/scamalytics.html" | grep -oE ">Yes<|>No<" | tr -d '<>' | head -n1)
        sc_prx=$(grep -A3 -i "Public Proxy" "$TMP_DIR/scamalytics.html" | grep -oE ">Yes<|>No<" | tr -d '<>' | head -n1)
        sc_bot=$(grep -A3 -i "Search Engine Robot" "$TMP_DIR/scamalytics.html" | grep -oE ">Yes<|>No<" | tr -d '<>' | head -n1)
    fi

    # 6. ipdata Factors
    local ipd_cc=$(jq_get "$TMP_DIR/ipdata.json" '.country_code')
    local ipd_prx=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_proxy')
    local ipd_tor=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_tor')
    local ipd_srv=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_datacenter')
    local ipd_a1=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_threat')
    local ipd_a2=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_known_abuser')
    local ipd_a3=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_known_attacker')
    local ipd_abu="N/A"
    [[ "$ipd_a1" == "false" && "$ipd_a2" == "false" && "$ipd_a3" == "false" ]] && ipd_abu="false"
    [[ "$ipd_a1" == "true" || "$ipd_a2" == "true" || "$ipd_a3" == "true" ]] && ipd_abu="true"

    # 7. IPinfo Factors
    local inf_cc=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.country')
    [ "$inf_cc" = "N/A" ] && inf_cc="$COUNTRY_CODE"
    local inf_prx=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.privacy.proxy')
    local inf_tor=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.privacy.tor')
    local inf_vpn=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.privacy.vpn')
    local inf_srv=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.privacy.hosting')

    # 8. ProxyCheck Factors
    local pck_prx=$(jq -r --arg ip "$TARGET_IP" '.[$ip].proxy // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null)
    local pck_vpn="no"; [ "$T_PCK_U" = "VPN" ] && pck_vpn="yes"
    local pck_srv="no"; [[ "$T_PCK_U" =~ ^(Hosting|VPN)$ ]] && pck_srv="yes"
    local pck_abu="no"; [ "${PCHECK_SCORE:-0}" -ge 50 ] && pck_abu="yes"

    printf "${C_CYAN}%-8s${C_RESET}" "Region:"; fmt_reg "$i2l_cc"; fmt_reg "$ipa_cc"; fmt_reg "$reg_cc"; fmt_reg "$pqs_cc"; fmt_reg "$sc_cc"; fmt_reg "$ipd_cc"; fmt_reg "$inf_cc"; fmt_reg "$COUNTRY_CODE"; echo ""
    printf "${C_CYAN}%-8s${C_RESET}" "Proxy:";  fmt_bool "$i2l_prx"; fmt_bool "$ipa_prx"; fmt_bool "$reg_prx"; fmt_bool "$pqs_prx"; fmt_bool "$sc_prx"; fmt_bool "$ipd_prx"; fmt_bool "$inf_prx"; fmt_bool "$pck_prx"; echo ""
    printf "${C_CYAN}%-8s${C_RESET}" "Tor:";    fmt_bool "$i2l_tor"; fmt_bool "$ipa_tor"; fmt_bool "$reg_tor"; fmt_bool "$pqs_tor"; fmt_bool "$sc_tor"; fmt_bool "$ipd_tor"; fmt_bool "$inf_tor"; fmt_bool "no"; echo ""
    printf "${C_CYAN}%-8s${C_RESET}" "VPN:";    fmt_bool "$i2l_vpn"; fmt_bool "$ipa_vpn"; fmt_bool "$reg_vpn"; fmt_bool "$pqs_vpn"; fmt_bool "$sc_vpn"; fmt_bool "N/A";      fmt_bool "$inf_vpn"; fmt_bool "$pck_vpn"; echo ""
    printf "${C_CYAN}%-8s${C_RESET}" "Server:"; fmt_bool "$i2l_srv"; fmt_bool "$ipa_srv"; fmt_bool "$reg_srv"; fmt_bool "N/A";      fmt_bool "$sc_srv"; fmt_bool "$ipd_srv"; fmt_bool "$inf_srv"; fmt_bool "$pck_srv"; echo ""
    printf "${C_CYAN}%-8s${C_RESET}" "Abuser:"; fmt_bool "$i2l_abu"; fmt_bool "$ipa_abu"; fmt_bool "$reg_abu"; fmt_bool "$pqs_abu"; fmt_bool "$sc_abu"; fmt_bool "$ipd_abu"; fmt_bool "N/A";      fmt_bool "$pck_abu"; echo ""
    printf "${C_CYAN}%-8s${C_RESET}" "Robot:";  fmt_bool "$i2l_bot"; fmt_bool "$ipa_bot"; fmt_bool "N/A";      fmt_bool "$pqs_bot"; fmt_bool "$sc_bot"; fmt_bool "N/A";      fmt_bool "N/A";      fmt_bool "no"; echo ""

    # === 5. STREAMING & AI (2 balanced rows of 6 cols: 8 + 6*9 = 62 chars!) ===
    if [ "$IS_LOCAL_IP" -eq 1 ]; then
        echo -e "${C_BOLD}5. Media & AI Accessibility (${IPV_LABEL} Strict)${C_RESET}"
        # Row 1: 6 Media Services
        local srvs=("tiktok:TikTok" "disney:Disney+" "netflix:Netflix" "youtube:YouTube" "spotify:Spotify" "twitch:Twitch")
        printf "${C_CYAN}%-8s${C_RESET}" "Media:"
        for item in "${srvs[@]}"; do printf "${C_CYAN}%-9s${C_RESET}" "${item#*:}"; done; echo ""
        printf "${C_CYAN}%-8s${C_RESET}" "Status:"
        for item in "${srvs[@]}"; do local st=$(cut -d'|' -f1 "$TMP_DIR/srv_${item%:*}" 2>/dev/null); fmt_srv_status "${st:-Block}"; printf " "; done; echo ""
        printf "${C_CYAN}%-8s${C_RESET}" "Region:"
        for item in "${srvs[@]}"; do
            local rg=$(cut -d'|' -f2 "$TMP_DIR/srv_${item%:*}" 2>/dev/null)
            [ -n "$rg" ] && [ "$rg" != "N/A" ] && printf "${C_GREEN}%-9s${C_RESET}" "  [${rg}]" || printf "%-9s" "   -"
        done; echo ""
        printf "${C_CYAN}%-8s${C_RESET}" "Type:"
        for item in "${srvs[@]}"; do local tp=$(cut -d'|' -f3 "$TMP_DIR/srv_${item%:*}" 2>/dev/null); fmt_srv_type "${tp:-N/A}"; printf " "; done; echo ""

        # Row 2: 4 AI + Reddit + Google Search (6 columns total = 62 chars)
        local ais=("ai_chatgpt:ChatGPT" "ai_claude:Claude" "ai_gemini:Gemini" "ai_jetbrains:JetBrn" "srv_reddit:Reddit")
        echo ""
        printf "${C_CYAN}%-8s${C_RESET}" "AI/Web:"
        for item in "${ais[@]}"; do printf "${C_CYAN}%-9s${C_RESET}" "${item#*:}"; done
        printf "${C_CYAN}%-9s${C_RESET}\n" "Google"

        printf "${C_CYAN}%-8s${C_RESET}" "Status:"
        for item in "${ais[@]}"; do local st=$(cut -d'|' -f1 "$TMP_DIR/${item%:*}" 2>/dev/null); fmt_srv_status "${st:-Block}"; printf " "; done
        local gbot=$(cat "$TMP_DIR/bot_google" 2>/dev/null)
        local g_gl=$(cat "$TMP_DIR/google_gl" 2>/dev/null)
        fmt_srv_status "${gbot:-Block}"; echo ""

        printf "${C_CYAN}%-8s${C_RESET}" "Region:"
        for item in "${ais[@]}"; do
            local rg=$(cut -d'|' -f2 "$TMP_DIR/${item%:*}" 2>/dev/null)
            [ -n "$rg" ] && [ "$rg" != "N/A" ] && printf "${C_GREEN}%-9s${C_RESET}" "  [${rg}]" || printf "%-9s" "   -"
        done
        [ -n "$g_gl" ] && [ "$g_gl" != "N/A" ] && printf "${C_GREEN}%-9s${C_RESET}" "  [${g_gl}]" || printf "%-9s" "   -"
        echo ""

        printf "${C_CYAN}%-8s${C_RESET}" "Type:"
        for item in "${ais[@]}"; do local tp=$(cut -d'|' -f3 "$TMP_DIR/${item%:*}" 2>/dev/null); fmt_srv_type "${tp:-N/A}"; printf " "; done
        [[ "$gbot" == *"200"* ]] && fmt_srv_type "200 OK" || fmt_srv_type "N/A"
        echo ""
    fi

    # === 6. EMAIL & DNSBL (60 chars max) ===
    if [ "$IPV_MODE" = "-4" ]; then
        echo -e "${C_BOLD}6. Email & Blacklist Detection (Top-30 RBL)${C_RESET}"
        if [ "$IS_LOCAL_IP" -eq 1 ]; then
            local any_port25=0
            for f in "$TMP_DIR"/mx_*; do [ -f "$f" ] && [ "$(cat "$f")" = "OK" ] && any_port25=1; done
            if [ "$any_port25" -eq 1 ]; then
                echo -e "${C_CYAN}Port 25 Outbound:${C_RESET} ${C_GREEN}${C_BOLD}Available${C_RESET}"
                printf "${C_CYAN}Conn: ${C_RESET}"
                for name in Gmail Outlook Yahoo Apple MailRU Proton; do
                    [ "$(cat "$TMP_DIR/mx_${name}" 2>/dev/null)" = "OK" ] && printf "${BG_GREEN}✓%-7s${C_RESET} " "$name" || printf "${BG_RED}✗%-7s${C_RESET} " "$name"
                done; echo ""
            else
                echo -e "${C_CYAN}Port 25 Outbound:${C_RESET} ${C_RED}${C_BOLD}Blocked${C_RESET}"
                echo -e "${C_CYAN}Conn:${C_RESET} ${C_RED}Remote Port 25 unreachable (Blocked by ISP)${C_RESET}"
            fi
        fi
        local total_rbl=0; local clean_rbl=0; local marked_rbl=0; local black_rbl=0; local listed_names=()
        for f in "$TMP_DIR"/rbl/*; do
            [ -f "$f" ] || continue
            total_rbl=$((total_rbl + 1)); local st=$(cat "$f"); local rbl_name=$(basename "$f")
            case "$st" in
                CLEAN)       clean_rbl=$((clean_rbl + 1)) ;;
                MARKED)      marked_rbl=$((marked_rbl + 1)); listed_names+=("${C_YELLOW}${rbl_name}${C_RESET}") ;;
                BLACKLISTED) black_rbl=$((black_rbl + 1)); listed_names+=("${C_RED}${rbl_name}${C_RESET}") ;;
            esac
        done
        echo -e "${C_CYAN}DNSBL:${C_RESET} ${C_BLUE}${C_BOLD}Total ${total_rbl}${C_RESET}  ${C_GREEN}${C_BOLD}Clean ${clean_rbl}${C_RESET}  ${C_YELLOW}${C_BOLD}Marked ${marked_rbl}${C_RESET}  ${C_RED}${C_BOLD}Blacklisted ${black_rbl}${C_RESET}"
        [ ${#listed_names[@]} -gt 0 ] && echo -e "${C_CYAN}Listed:${C_RESET} ${listed_names[*]}"
    fi
    echo -e "${C_CYAN}================================================================${C_RESET}"
}

# ==============================================================================
# ENTRY POINT: DUAL-STACK ORCHESTRATOR
# ==============================================================================
check_deps

if [ -n "$CUSTOM_IP" ]; then
    if [[ "$CUSTOM_IP" == *":"* ]]; then
        run_check_for_stack "-6" "IPv6" "$CUSTOM_IP" 0
    else
        run_check_for_stack "-4" "IPv4" "$CUSTOM_IP" 0
    fi
    exit 0
fi

IPV4_ADDR=""
IPV6_ADDR=""

if [ "$STACK_MODE" = "dual" ] || [ "$STACK_MODE" = "4" ]; then
    IPV4_ADDR=$(curl -s4m 4 https://api.ipify.org || curl -s4m 4 https://icanhazip.com || curl -s4m 4 https://ipinfo.io/ip)
fi

if [ "$STACK_MODE" = "dual" ] || [ "$STACK_MODE" = "6" ]; then
    IPV6_ADDR=$(curl -s6m 4 https://api6.ipify.org || curl -s6m 4 https://icanhazip.com || curl -s6m 4 https://ipinfo.io/ip)
fi

if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
    echo -e "${C_RED}[X] Failed to detect any public IPv4 or IPv6 address.${C_RESET}"
    exit 1
fi

[ -n "$IPV4_ADDR" ] && run_check_for_stack "-4" "IPv4" "$IPV4_ADDR" 1
[ -n "$IPV6_ADDR" ] && run_check_for_stack "-6" "IPv6" "$IPV6_ADDR" 1
