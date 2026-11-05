#!/usr/bin/env bash
# ==============================================================================
# IPQuality | Dual-Stack IP Type, Fraud Score, GeoIP, Platforms, AI, Mail & CDN
# ==============================================================================

set -uo pipefail
shopt -s extglob

export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C

# --- UI Layout Constants (82-col Side-by-Side Cards) ---
readonly CARD_GAP=2
readonly LEFT_CARD_WIDTH=40
readonly RIGHT_CARD_WIDTH=40
readonly FULL_CARD_WIDTH=$((LEFT_CARD_WIDTH + CARD_GAP + RIGHT_CARD_WIDTH))

readonly CARD_TOP_LEFT="╭"
readonly CARD_TOP_RIGHT="╮"
readonly CARD_BOTTOM_LEFT="╰"
readonly CARD_BOTTOM_RIGHT="╯"
readonly CARD_SIDE="│"
readonly CARD_HORIZONTAL="─"
readonly HEADER_MARK="┃"
readonly SUMMARY_BAR_CHAR="━"
readonly SUMMARY_BAR_REST_CHAR="─"

readonly CLEAR_LINE=$'\r\033[K'
readonly SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
readonly BAR_WIDTH=24

readonly UA_BROWSER="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
readonly ANSI_SEQUENCE=$'\033\[+([0-9;])m'

# --- Colors ---
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_TITLE=$'\033[1;36m'
    readonly C_VALUE=$'\033[1m'
    readonly C_DIM=$'\033[0;90m'
    readonly C_YES=$'\033[1;32m'
    readonly C_NO=$'\033[1;31m'
    readonly C_WARN=$'\033[1;33m'
    readonly C_BAR=$'\033[0;36m'
    readonly C_BADGE=$'\033[1;30;46m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_TITLE="" C_VALUE="" C_DIM="" C_YES="" C_NO="" C_WARN="" C_BAR="" C_BADGE="" C_RESET=""
fi

# --- State ---
STACK_MODE="dual"
CUSTOM_IP=""
MASK_IP=false
IPV4_ADDR=""
IPV6_ADDR=""
IS_LOCAL_IP=1
FRAME_IDX=0
VERDICT_CC=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -4|--ipv4) STACK_MODE="4"; shift ;;
        -6|--ipv6) STACK_MODE="6"; shift ;;
        -i|--ip)   CUSTOM_IP="${2:-}"; shift 2 ;;
        -m|--mask) MASK_IP=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: bash ipcheck.sh [OPTIONS]

Options:
  -4, --ipv4       Check IPv4 only
  -6, --ipv6       Check IPv6 only
  -i, --ip IP      Check a custom target IP address
  -m, --mask       Mask IP addresses in the header
  -h, --help       Show this help
EOF
            exit 0
            ;;
        *) shift ;;
    esac
done

WORK_DIR=$(mktemp -d -t ipq.XXXXXX)
cleanup() {
    local pid
    for pid in $(jobs -pr 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

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
            elif command -v apk &>/dev/null; then
                apk add --no-cache "${missing[@]}" bind-tools &>/dev/null
            fi
        else
            printf '%sError:%s Missing dependencies (%s). Run as root or install them.\n' "$C_NO" "$C_RESET" "${missing[*]}" >&2
            exit 1
        fi
    fi
}

# --- UI Helpers ---
visible_length() {
    local plain="${1//$ANSI_SEQUENCE/}"
    printf '%d' "${#plain}"
}

repeat_char() {
    local char="$1" count="$2" line
    ((count <= 0)) && return
    printf -v line '%*s' "$count" ''
    printf '%s' "${line// /$char}"
}

pad() {
    local text="$1" width="$2" fill
    fill=$((width - $(visible_length "$text")))
    ((fill < 0)) && fill=0
    printf '%s%*s' "$text" "$fill" ''
}

paint() {
    printf '%s%s%s' "$1" "$2" "$C_RESET"
}

draw_spinner() {
    local label="$1" done_cnt="$2" total_cnt="$3"
    [[ ! -t 2 ]] && return
    local frame="${SPINNER_FRAMES[FRAME_IDX % ${#SPINNER_FRAMES[@]}]}"
    FRAME_IDX=$((FRAME_IDX + 1))
    local filled=$((BAR_WIDTH * done_cnt / (total_cnt > 0 ? total_cnt : 1)))
    local bar_done bar_left
    bar_done=$(repeat_char "$SUMMARY_BAR_CHAR" "$filled")
    bar_left=$(repeat_char "$SUMMARY_BAR_REST_CHAR" $((BAR_WIDTH - filled)))
    printf '%s%s%s%s  %-22s %s%s%s%s%s  %s%d/%d%s' \
        "$CLEAR_LINE" "$C_TITLE" "$frame" "$C_RESET" "$label" \
        "$C_BAR" "$bar_done" "$C_DIM" "$bar_left" "$C_RESET" \
        "$C_DIM" "$done_cnt" "$total_cnt" "$C_RESET" >&2
}

wait_with_progress() {
    local label="$1" total
    total=$(jobs -pr | wc -l)
    ((total == 0)) && return
    while true; do
        local running
        running=$(jobs -pr | wc -l)
        ((running == 0)) && break
        draw_spinner "$label" $((total - running)) "$total"
        sleep 0.1
    done
    [[ -t 2 ]] && printf '%s' "$CLEAR_LINE" >&2
}

print_card_top() {
    local title="$1" width="$2" summary="${3:-}" label
    label=" $(paint "$C_TITLE" "$title") "
    if [[ -n "$summary" ]]; then
        label=" $(paint "$C_TITLE" "$title") $(paint "$C_DIM" "·") $summary "
    fi
    local dash_cnt=$((width - 3 - $(visible_length "$label")))
    ((dash_cnt < 1)) && dash_cnt=1
    printf '%s%s%s%s%s%s%s%s\n' \
        "$C_DIM" "$CARD_TOP_LEFT" "$CARD_HORIZONTAL" "$C_RESET" \
        "$label" \
        "$C_DIM" "$(repeat_char "$CARD_HORIZONTAL" "$dash_cnt")$CARD_TOP_RIGHT" "$C_RESET"
}

print_card_line() {
    local line="$1" width="$2" fill
    fill=$((width - 4 - $(visible_length "$line")))
    ((fill < 0)) && fill=0
    printf '%s%s%s %s%*s %s%s%s\n' \
        "$C_DIM" "$CARD_SIDE" "$C_RESET" "$line" "$fill" '' "$C_DIM" "$CARD_SIDE" "$C_RESET"
}

print_card_bottom() {
    local width="$1"
    printf '%s%s%s%s%s\n' \
        "$C_DIM" "$CARD_BOTTOM_LEFT" "$(repeat_char "$CARD_HORIZONTAL" $((width - 2)))" "$CARD_BOTTOM_RIGHT" "$C_RESET"
}

render_card() {
    local title="$1" width="$2" height="$3" summary="${4:-}"
    local -a lines=()
    mapfile -t lines
    while ((${#lines[@]} > 0)) && [[ -z "${lines[-1]}" ]]; do unset 'lines[-1]'; done
    ((${#lines[@]} > height)) && height="${#lines[@]}"

    print_card_top "$title" "$width" "$summary"
    local i
    for ((i = 0; i < height; i++)); do
        print_card_line "${lines[i]:-}" "$width"
    done
    print_card_bottom "$width"
}

render_card_pair() {
    local l_title="$1" r_title="$2" l_body="$3" r_body="$4" l_sum="${5:-}" r_sum="${6:-}"
    local -a l_lines=() r_lines=() l_card=() r_card=()
    mapfile -t l_lines <<<"$l_body"
    mapfile -t r_lines <<<"$r_body"
    local height="${#l_lines[@]}"
    ((${#r_lines[@]} > height)) && height="${#r_lines[@]}"

    mapfile -t l_card < <(printf '%s\n' "${l_lines[@]}" | render_card "$l_title" "$LEFT_CARD_WIDTH" "$height" "$l_sum")
    mapfile -t r_card < <(printf '%s\n' "${r_lines[@]}" | render_card "$r_title" "$RIGHT_CARD_WIDTH" "$height" "$r_sum")
    local i
    for ((i = 0; i < ${#l_card[@]}; i++)); do
        printf '%s%*s%s\n' "${l_card[i]}" "$CARD_GAP" '' "${r_card[i]:-}"
    done
}

print_bar_block() {
    local -a block_lines=()
    local line
    mapfile -t block_lines
    for line in "${block_lines[@]}"; do
        line="${line%%+( )}"
        if [[ -z "$line" ]]; then
            printf ' %s%s%s\n' "$C_BAR" "$HEADER_MARK" "$C_RESET"
        else
            printf ' %s%s%s %s\n' "$C_BAR" "$HEADER_MARK" "$C_RESET" "$line"
        fi
    done
    printf '\n'
}

# --- IATA Airport Code -> ISO Country Mapper (Offline + API Fallback) ---
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
        LCA|PFO) printf 'CY' ;;
        MLA) printf 'MT' ;;
        KEF) printf 'IS' ;;
        KBP|IEV|LWO|ODS) printf 'UA' ;;
        KIV|RMO) printf 'MD' ;;
        MSQ) printf 'BY' ;;
        SVO|DME|VKO|LED|KZN|SVX|OVB|AER|ROV) printf 'RU' ;;
        TBS) printf 'GE' ;;
        EVN) printf 'AM' ;;
        GYD) printf 'AZ' ;;
        ALA|NQZ|TSE) printf 'KZ' ;;
        TAS) printf 'UZ' ;;
        FRU) printf 'KG' ;;
        TLV|HFA) printf 'IL' ;;
        DXB|AUH|SHJ) printf 'AE' ;;
        DOH) printf 'QA' ;;
        BAH) printf 'BH' ;;
        KWI) printf 'KW' ;;
        MCT) printf 'OM' ;;
        RUH|JED|DMM) printf 'SA' ;;
        AMM) printf 'JO' ;;
        CAI) printf 'EG' ;;
        CMN) printf 'MA' ;;
        JNB|CPT|DUR) printf 'ZA' ;;
        LOS|ABV) printf 'NG' ;;
        NBO) printf 'KE' ;;
        IAD|JFK|EWR|LAX|SFO|SJC|ORD|DFW|MIA|ATL|SEA|DEN|BOS|PHX|IAH|MSP|DTW|PHL|CLT|SLC|LAS|MCO|PDX|BNA|RDU|MCI|CMH|IND|PIT|STL|BUF) printf 'US' ;;
        YYZ|YVR|YUL|YYC|YOW|YEG|YWG|YHZ) printf 'CA' ;;
        MEX|GDL|MTY|QRO) printf 'MX' ;;
        GRU|GIG|VCP|BSB|CNF|POA|REC|FOR|SSA|CWB) printf 'BR' ;;
        EZE|AEP|COR) printf 'AR' ;;
        SCL) printf 'CL' ;;
        BOG|MDE) printf 'CO' ;;
        LIM) printf 'PE' ;;
        PTY) printf 'PA' ;;
        SJO) printf 'CR' ;;
        UIO|GYE) printf 'EC' ;;
        MVD) printf 'UY' ;;
        NRT|HND|KIX|ITM|NGO|FUK|CTS) printf 'JP' ;;
        ICN|GMP|PUS) printf 'KR' ;;
        SIN) printf 'SG' ;;
        HKG) printf 'HK' ;;
        TPE|KHH) printf 'TW' ;;
        BKK|DMK|HKT) printf 'TH' ;;
        KUL|JHB) printf 'MY' ;;
        CGK|SUB|DPS) printf 'ID' ;;
        MNL|CEB) printf 'PH' ;;
        SGN|HAN|DAD) printf 'VN' ;;
        BOM|DEL|BLR|MAA|HYD|CCU|AMD|PNQ) printf 'IN' ;;
        KHI|LHE|ISB) printf 'PK' ;;
        DAC) printf 'BD' ;;
        CMB) printf 'LK' ;;
        KTM) printf 'NP' ;;
        SYD|MEL|BNE|PER|ADL|CBR) printf 'AU' ;;
        AKL|WLG|CHC) printf 'NZ' ;;
        PEK|PKX|PVG|SHA|CAN|SZX|CTU|HGH|WUH|XIY|NKG) printf 'CN' ;;
        *)
            local res
            res=$(curl -s4m 3 "https://www.air-port-codes.com/api/v1/single" \
                -H "APC-Auth: 96dc04b3fb" -H "Referer: https://www.air-port-codes.com/" \
                --data "iata=$iata" 2>/dev/null | jq -r '.airport.country.iso // empty' 2>/dev/null || true)
            printf '%s' "$res"
            ;;
    esac
}

# --- Formatters (Full Words: ISP, Hosting, Business, Mobile...) ---
normalize_ip_type() {
    local val="${1,,}"
    case "$val" in
        *hosting*|*datacenter*|*dch*|*transit*|*cloud*|*server*|*vpn*|*colocation*)
            printf 'Hosting' ;;
        *business*|*com*|*commercial*|*corporate*|*org*|*bank*)
            printf 'Business' ;;
        *isp*|*residential*|*home*|*line*|*fixed*)
            printf 'ISP' ;;
        *mobile*|*mob*|*cellular*|*wireless*)
            printf 'Mobile' ;;
        *cdn*|*content*)
            printf 'CDN' ;;
        *edu*|*university*|*school*|*college*)
            printf 'Education' ;;
        *gov*|*mil*)
            printf 'Gov' ;;
        *spider*|*ses*|*crawler*|*bot*|*search*)
            printf 'Crawler' ;;
        *)
            printf 'N/A' ;;
    esac
}

format_type_cell() {
    local norm width="$2"
    norm=$(normalize_ip_type "$1")
    case "$norm" in
        ISP|Mobile)             paint "$C_YES"  "$(pad "$norm" "$width")" ;;
        Business|Education|Gov) paint "$C_WARN" "$(pad "$norm" "$width")" ;;
        Hosting|CDN|Crawler)    paint "$C_NO"   "$(pad "$norm" "$width")" ;;
        *)                      paint "$C_DIM"  "$(pad "—" "$width")" ;;
    esac
}

format_score_cell() {
    local score="$1" width="$2" suffix="${3:-/100}"
    if [[ -z "$score" || "$score" == "N/A" || "$score" == "null" ]]; then
        paint "$C_DIM" "$(pad "—" "$width")"
        return
    fi
    local num="${score%%.*}"
    num="${num//[^0-9]/}"
    if [[ -z "$num" ]]; then
        paint "$C_DIM" "$(pad "—" "$width")"
        return
    fi
    local lvl="Low" color="$C_YES"
    if ((num >= 65)); then
        lvl="High"; color="$C_NO"
    elif ((num >= 25)); then
        lvl="Med"; color="$C_WARN"
    fi
    paint "$color" "$(pad "${score}${suffix} ${lvl}" "$width")"
}

format_bool_cell() {
    local val="$1" width="$2"
    case "$val" in
        true|Yes|yes|1) paint "$C_NO"  "$(pad "✗ Yes" "$width")" ;;
        false|No|no|0)  paint "$C_YES" "$(pad "✓ No" "$width")" ;;
        *)              paint "$C_DIM" "$(pad "—" "$width")" ;;
    esac
}

format_cc_cell() {
    local cc="$1" width="$2"
    if [[ -z "$cc" || "$cc" == "N/A" || "$cc" == "null" ]]; then
        paint "$C_DIM" "$(pad "?" "$width")"
    elif [[ "$cc" == "NoIPv6" || "$cc" == "-" ]]; then
        paint "$C_DIM" "$(pad "-" "$width")"
    elif [[ "$cc" == "Block" ]]; then
        paint "$C_NO" "$(pad "⊘" "$width")"
    elif [[ -n "$VERDICT_CC" && "$cc" != "$VERDICT_CC" ]]; then
        paint "$C_WARN" "$(pad "$cc" "$width")"
    else
        paint "$C_VALUE" "$(pad "$cc" "$width")"
    fi
}

format_srv_cell() {
    local raw="$1" width="$2"
    local status="${raw%%|*}"
    local rest="${raw#*|}"
    local reg="${rest%%|*}"
    [[ "$reg" == "N/A" || -z "$reg" ]] && reg=""
    case "$status" in
        Yes|Clean|Open)
            paint "$C_YES" "$(pad "✓ ${reg:-OK}" "$width")" ;;
        OrigOnly|NoPrem|Captcha|VideoAds)
            paint "$C_WARN" "$(pad "⚠ ${status}" "$width")" ;;
        NoIPv6)
            paint "$C_DIM" "$(pad "- no IPv6" "$width")" ;;
        Block|No)
            paint "$C_NO" "$(pad "✗ ${reg:-Block}" "$width")" ;;
        *)
            paint "$C_DIM" "$(pad "—" "$width")" ;;
    esac
}

jq_get() {
    local file="$1" query="$2"
    [[ ! -s "$file" ]] && { printf 'N/A'; return; }
    local res
    res=$(jq -r "(${query}) | if . == null or . == \"\" then \"N/A\" else tostring end" "$file" 2>/dev/null || true)
    [[ -z "$res" ]] && res="N/A"
    printf '%s' "$res"
}

# ==============================================================================
# DATA COLLECTION FOR ONE STACK (4 or 6)
# ==============================================================================
collect_stack_data() {
    local v="$1"
    local ip="$2"
    local flag="-$v"
    local dir="$WORK_DIR/v${v}"
    mkdir -p "$dir"

    # 1. MaxMind Direct Token + check.place + RIPE RDAP & Stat
    (
        if [[ -s "$WORK_DIR/mm_token" ]]; then
            local mmt
            mmt=$(<"$WORK_DIR/mm_token")
            curl -sLm 5 -A "$UA_BROWSER" -H "Authorization: Bearer $mmt" \
                "https://geoip.maxmind.com/geoip/v2.1/city/${ip}?demo=1" > "$dir/maxmind_direct.json"
        fi
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?lang=en" > "$dir/maxmind.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://stat.ripe.net/data/prefix-overview/data.json?resource=${ip}" > "$dir/ripe_asn.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://stat.ripe.net/data/rir-stats-country/data.json?resource=${ip}" > "$dir/ripe_reg.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://rdap.db.ripe.net/ip/${ip}" > "$dir/ripe_rdap.json"
    ) &

    # 2. ipinfo.io (direct widget)
    (
        local url="https://ipinfo.io/widget/demo/${ip}"
        [[ "$v" == "6" ]] && url="https://v6.ipinfo.io/widget/demo/${ip}"
        curl -sLm 5 -A "$UA_BROWSER" -H "Referer: https://ipinfo.io/" "$url" > "$dir/ipinfo.json"
    ) &

    # 3. ipregistry.co (direct API)
    curl -sLm 6 --compressed -A "$UA_BROWSER" \
        -H "Origin: https://ipregistry.co" -H "Referer: https://ipregistry.co/" \
        "https://api.ipregistry.co/${ip}?hostname=true&key=sb69ksjcajfs4c" > "$dir/ipregistry.json" &

    # 4. ipapi.is (direct official API)
    (
        curl -sLm 6 -A "$UA_BROWSER" "https://api.ipapi.is/?q=${ip}" > "$dir/ipapi_is.json"
        if ! jq -e '.asn' "$dir/ipapi_is.json" &>/dev/null; then
            curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?db=ipapi" > "$dir/ipapi_is.json"
        fi
    ) &

    # 5. ipquery.io, ProxyCheck.io, ip-api.com, ipwho.is, ipbase.com, ipapi.co, country.is, geojs.io
    curl -sLm 6 -A "$UA_BROWSER" "https://api.ipquery.io/${ip}" > "$dir/ipquery.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://proxycheck.io/v2/${ip}?vpn=1&asn=1&risk=1" > "$dir/proxycheck.json" &
    curl -sLm 6 -A "$UA_BROWSER" -H "Origin: https://ip-api.com" "https://demo.ip-api.com/json/${ip}?fields=66842623" > "$dir/ip_api.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://ipwho.is/${ip}" > "$dir/ipwhois.json" &
    curl -sLm 6 -A "$UA_BROWSER" "https://api.ipbase.com/v2/info?ip=${ip}" > "$dir/ipbase.json" &
    curl -sLm 5 -A "$UA_BROWSER" -H "Referer: https://ipapi.co/" "https://ipapi.co/${ip}/json/" > "$dir/ipapi_co.json" &
    curl -sLm 5 -A "$UA_BROWSER" "https://api.country.is/${ip}" > "$dir/country_is.json" &
    curl -sLm 5 -A "$UA_BROWSER" "https://get.geojs.io/v1/ip/country/${ip}.json" > "$dir/geojs.json" &

    # 6. Scamalytics, IP2Location, ipdata.co, AbuseIPDB, IPQS, DB-IP
    (
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?db=scamalytics" > "$dir/scamalytics.json"
        if ! jq -e '.scamalytics.scamalytics_score' "$dir/scamalytics.json" &>/dev/null; then
            curl -sLm 6 -A "$UA_BROWSER" "https://scamalytics.com/ip/${ip}" > "$dir/scamalytics.html"
        fi
    ) &
    (
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?db=ip2location" > "$dir/ip2location.json"
        curl -sLm 5 -A "$UA_BROWSER" "https://api.ip2location.io/?ip=${ip}" > "$dir/ip2loc_direct.json"
    ) &
    (
        curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?db=ipdata" > "$dir/ipdata.json"
        if ! jq -e '.asn' "$dir/ipdata.json" &>/dev/null; then
            local k
            k=$(curl -sLm 4 -A "$UA_BROWSER" "https://ipdata.co" 2>/dev/null | grep -oE 'api-key=[a-zA-Z0-9]+' | head -n1 | cut -d= -f2 || true)
            [[ -n "$k" ]] && curl -sLm 5 -A "$UA_BROWSER" -H "Referer: https://ipdata.co/" "https://api.ipdata.co/${ip}?api-key=${k}" > "$dir/ipdata.json"
        fi
    ) &
    curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?db=abuseipdb" > "$dir/abuseipdb.json" &
    curl -sLm 5 -A "$UA_BROWSER" "https://ipinfo.check.place/${ip}?db=ipqualityscore" > "$dir/ipqs.json" &
    (
        if ((IS_LOCAL_IP == 1)); then
            local dbk
            dbk=$(curl -sL "$flag" -m 4 -A "$UA_BROWSER" "https://db-ip.com/api/core/" 2>/dev/null | sed -n 's/.*data-api-key="\([^"]*\)".*/\1/p' | head -n1 || true)
            [[ -n "$dbk" ]] && curl -sL "$flag" -m 5 -A "$UA_BROWSER" -H "Origin: https://db-ip.com" -H "Referer: https://db-ip.com/" "https://api.db-ip.com/v2/${dbk}/self" > "$dir/dbip.json"
        fi
        [[ ! -s "$dir/dbip.json" ]] && curl -sLm 5 -A "$UA_BROWSER" "https://api.db-ip.com/v2/free/${ip}" > "$dir/dbip.json"
    ) &

    # 7. PTR & DNSBL
    (
        if command -v dig &>/dev/null; then
            dig +short -x "$ip" 2>/dev/null | head -n1 | sed 's/\.$//' > "$dir/ptr.txt"
        elif command -v host &>/dev/null; then
            host "$ip" 2>/dev/null | awk '/domain name pointer/ {print $5}' | sed 's/\.$//' | head -n1 > "$dir/ptr.txt"
        fi
    ) &
    (
        local rev=""
        if [[ "$ip" == *":"* ]]; then
            command -v python3 &>/dev/null && rev=$(python3 -c "import ipaddress; print('.'.join(reversed(ipaddress.ip_address('$ip').exploded.replace(':',''))))" 2>/dev/null || true)
        else
            rev=$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$ip")
        fi
        mkdir -p "$dir/rbl"
        if [[ -n "$rev" ]]; then
            for rbl in zen.spamhaus.org b.barracudacentral.org bl.spamcop.net dnsbl.sorbs.net dnsbl-1.uceprotect.net psbl.surriel.com db.wpbl.info ix.dnsbl.manitu.net 0spam.fusionzero.com rbl.interserver.net; do
                (
                    local r=""
                    command -v dig &>/dev/null && r=$(dig +short +time=2 +tries=1 "${rev}.${rbl}" A 2>/dev/null | grep -E '^127\.0\.0\.[0-9]+$' || true)
                    [[ -n "$r" && "$r" != "127.0.0.255" ]] && printf '%s\n' "$rbl" > "$dir/rbl/$rbl"
                ) &
            done
            wait
        fi
    ) &

    # 8. Local Stack Checks: Platforms, Streaming, AI, Mail & 6 CDNs!
    if ((IS_LOCAL_IP == 1)); then
        # --- CDN 1: Cloudflare ---
        (
            local cf_meta cf_cc cf_iata
            cf_meta=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -H "Referer: https://speed.cloudflare.com" "https://speed.cloudflare.com/meta" 2>/dev/null || true)
            cf_cc=$(jq -r '.colo.cca2 // empty' <<<"$cf_meta" 2>/dev/null || true)
            cf_iata=$(jq -r '.colo.iata // empty' <<<"$cf_meta" 2>/dev/null || true)
            if [[ -z "$cf_iata" ]]; then
                local trc
                trc=$(curl -sL "$flag" -m 4 -A "$UA_BROWSER" "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)
                [[ "$trc" =~ colo=([A-Z]{3}) ]] && cf_iata="${BASH_REMATCH[1]}"
                [[ "$trc" =~ loc=([A-Z]{2}) ]] && cf_cc="${BASH_REMATCH[1]}"
            fi
            [[ -n "$cf_iata" && -z "$cf_cc" ]] && cf_cc=$(iata_to_country "$cf_iata")
            printf '%s|%s\n' "${cf_cc:--}" "${cf_iata:--}" > "$dir/cdn_cloudflare"
        ) &

        # --- CDN 2: YouTube (Google GGC) ---
        (
            local yt_map node="" iata="" cc=""
            yt_map=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://redirector.googlevideo.com/report_mapping?di=no" 2>/dev/null || true)
            [[ "$yt_map" =~ =\>\ ([^[:space:]]+) ]] && node="${BASH_REMATCH[1]}"
            node="${node%%.*}"
            if [[ "$node" =~ ^([a-z]{3})[0-9] || "$node" =~ ^[a-z]+-([a-z]{3})[0-9] || "$node" =~ ^[a-z]{2}([a-z]{3})[a-z]-[a-z0-9]+$ ]]; then
                iata="${BASH_REMATCH[1]^^}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${node:-${iata:--}}" > "$dir/cdn_youtube"
        ) &

        # --- CDN 3: Netflix (Fast.com OCA) & Netflix Streaming ---
        (
            local nf_fast nf_reg nf_url node="" iata="" oca_cc=""
            nf_fast=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" 2>/dev/null || true)
            nf_reg=$(jq -r '.client.location.country // empty' <<<"$nf_fast" 2>/dev/null || true)
            oca_cc=$(jq -r '.targets[0].location.country // empty' <<<"$nf_fast" 2>/dev/null || true)
            nf_url=$(jq -r '.targets[0].url // empty' <<<"$nf_fast" 2>/dev/null || true)
            if [[ "$nf_url" =~ ^https://ipv[46]-([a-z0-9]+-([a-z]{3})[0-9]+[a-z0-9-]*)\. ]]; then
                node="${BASH_REMATCH[1]}"
                iata="${BASH_REMATCH[2]^^}"
            fi
            [[ -z "$oca_cc" && -n "$iata" ]] && oca_cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${oca_cc:--}" "${node:-${iata:--}}" > "$dir/cdn_netflix"

            local nf_code
            nf_code=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null || true)
            if [[ "$nf_code" == "000" && "$v" == "6" ]]; then
                echo "NoIPv6|N/A" > "$dir/srv_netflix"
            elif [[ "$nf_code" == "200" ]]; then
                echo "Yes|${nf_reg:-OK}" > "$dir/srv_netflix"
            else
                echo "OrigOnly|${nf_reg}" > "$dir/srv_netflix"
            fi
        ) &

        # --- CDN 4: Fastly Edge POP ---
        (
            local fs_hdr pop="" iata="" cc=""
            fs_hdr=$(curl -sIL "$flag" -m 5 -A "$UA_BROWSER" "https://www.fastly.com/robots.txt" 2>/dev/null | tr -d '\r' || true)
            if [[ "$fs_hdr" =~ [Xx]-[Ss]erved-[Bb]y:\ *([^[:space:],]+) ]]; then
                pop="${BASH_REMATCH[1]}"
                pop="${pop#cache-}"
                if [[ "$pop" =~ -([A-Z]{3})$ ]]; then
                    iata="${BASH_REMATCH[1]}"
                elif [[ "$pop" =~ ^([a-z]{3}) ]]; then
                    iata="${BASH_REMATCH[1]^^}"
                fi
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${pop:--}" > "$dir/cdn_fastly"
        ) &

        # --- CDN 5: AWS CloudFront Edge ---
        (
            local cf_hdr pop="" iata="" cc=""
            cf_hdr=$(curl -sIL "$flag" -m 5 -A "$UA_BROWSER" "https://d1.awsstatic.com/logos/aws-logo-lockups/poweredbyaws/PB_AWS_logo_RGB_stacked_REV_SQ.91cd4af40773cbfbd15577a3c2b8a346fe3e8fa2.png" 2>/dev/null | tr -d '\r' || true)
            if [[ "$cf_hdr" =~ [Xx]-[Aa]mz-[Cc]f-[Pp]op:\ *([A-Za-z0-9-]+) ]]; then
                pop="${BASH_REMATCH[1]}"
                iata="${pop:0:3}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${pop:--}" > "$dir/cdn_cloudfront"
        ) &

        # --- CDN 6: BunnyCDN Edge ---
        (
            local bn_hdr pop="" cc=""
            bn_hdr=$(curl -sIL "$flag" -m 5 -A "$UA_BROWSER" "https://bunny.net/robots.txt" 2>/dev/null | tr -d '\r' || true)
            if [[ "$bn_hdr" =~ [Ss]erver:\ *BunnyCDN-([A-Z]{2}[0-9]*-[0-9]+) ]]; then
                pop="${BASH_REMATCH[1]}"
                cc="${pop:0:2}"
            fi
            printf '%s|%s\n' "${cc:--}" "${pop:--}" > "$dir/cdn_bunny"
        ) &

        # --- Platforms Geo (Google, Steam, Apple, Microsoft, PlayStation, JetBrains, Ookla, Reddit) ---
        (
            local g_res g_cc=""
            g_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://accounts.google.com/v3/signin/identifier?flowName=GlifSetupAndroid" 2>/dev/null || true)
            [[ "$g_res" =~ name=\"region\"\ value=\"([^\"]*)\" ]] && g_cc="${BASH_REMATCH[1]}"
            printf '%s\n' "${g_cc:-N/A}" > "$dir/plat_google"
            if [[ -n "$g_cc" && ! "$g_cc" =~ ^(RU|BY|CN|HK|IR|KP|CU|SY)$ ]]; then
                echo "Yes|${g_cc}" > "$dir/ai_gemini"
            else
                echo "Block|${g_cc}" > "$dir/ai_gemini"
            fi
        ) &
        (
            local st_hdr st_cc=""
            st_hdr=$(curl -sIL "$flag" -m 5 -A "$UA_BROWSER" "https://store.steampowered.com" 2>/dev/null | tr -d '\r' || true)
            [[ "$st_hdr" =~ steamCountry=([A-Z]{2}) ]] && st_cc="${BASH_REMATCH[1]}"
            [[ -z "$st_hdr" && "$v" == "6" ]] && st_cc="-"
            printf '%s\n' "${st_cc:-N/A}" > "$dir/plat_steam"
        ) &
        (
            local ap_cc
            ap_cc=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://gspe1-ssl.ls.apple.com/pep/gcc" 2>/dev/null | tr -d '[:space:]' || true)
            [[ ! "$ap_cc" =~ ^[A-Z]{2}$ ]] && ap_cc="N/A"
            printf '%s\n' "$ap_cc" > "$dir/plat_apple"
        ) &
        (
            local ms_res ms_cc=""
            ms_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://login.live.com" 2>/dev/null || true)
            [[ "$ms_res" =~ \"sRequestCountry\":\"([A-Z]{2})\" ]] && ms_cc="${BASH_REMATCH[1]}"
            printf '%s\n' "${ms_cc:-N/A}" > "$dir/plat_microsoft"
        ) &
        (
            local ps_hdr ps_cc=""
            ps_hdr=$(curl -sIL "$flag" -m 5 -A "$UA_BROWSER" "https://www.playstation.com" 2>/dev/null | tr -d '\r' || true)
            [[ "$ps_hdr" =~ [Cc]ookie:\ *country=([A-Za-z]{2}) ]] && ps_cc="${BASH_REMATCH[1]^^}"
            printf '%s\n' "${ps_cc:-N/A}" > "$dir/plat_playstation"
        ) &
        (
            local jb_cc
            jb_cc=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://data.services.jetbrains.com/geo" 2>/dev/null | jq -r '.code // empty' 2>/dev/null || true)
            printf '%s\n' "${jb_cc:-N/A}" > "$dir/plat_jetbrains"
        ) &
        (
            local ok_cc
            ok_cc=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://www.speedtest.net/api/js/config-sdk" 2>/dev/null | jq -r '.location.countryCode // empty' 2>/dev/null || true)
            printf '%s\n' "${ok_cc:-N/A}" > "$dir/plat_ookla"
        ) &
        (
            local rd_res rd_code rd_reg=""
            rd_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -w "\nCODE:%{http_code}" "https://www.reddit.com/api/v1/not-found" 2>/dev/null || true)
            rd_code="${rd_res##*CODE:}"
            [[ "$rd_res" =~ country\ code:\ ([A-Z]{2}) ]] && rd_reg="${BASH_REMATCH[1]}"
            if [[ "$rd_code" == "403" ]]; then
                echo "Block" > "$dir/plat_reddit"
                echo "Block|${rd_reg}" > "$dir/srv_reddit"
            else
                echo "${rd_reg:-N/A}" > "$dir/plat_reddit"
                echo "Yes|${rd_reg:-OK}" > "$dir/srv_reddit"
            fi
        ) &

        # --- Streaming & Availability (YouTube Premium, Disney+, TikTok, Spotify, Twitch) ---
        (
            local yt_sw gl prem_res
            yt_sw=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://www.youtube.com/sw.js_data" 2>/dev/null || true)
            gl=$(jq -r '.[0][2][0][0][1] // empty' <<<"${yt_sw#")]}'"}" 2>/dev/null || true)
            prem_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://www.youtube.com/youtubei/v1/browse" \
                -H "Content-Type: application/json" \
                -d '{"context":{"client":{"clientName":"MWEB","clientVersion":"2.20261020.00.00","hl":"en","gl":"US"}},"browseId":"SPunlimited"}' 2>/dev/null || true)
            if [[ -z "$yt_sw" && "$v" == "6" ]]; then
                echo "NoIPv6|N/A" > "$dir/srv_youtube"
            elif [[ "$prem_res" == *"premiumPurchaseButtonRenderer"* ]]; then
                echo "Yes|${gl:-US}" > "$dir/srv_youtube"
            else
                echo "NoPrem|${gl:-RU}" > "$dir/srv_youtube"
            fi
        ) &
        (
            local dp_res dp_reg dp_ok
            dp_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
                -H "Authorization: Bearer ZGlzbmV5JmFuZHJvaWQmMS4wLjA.bkeb0m230uUhv8qrAXuNu39tbE_mD5EEhM_NAcohjyA" \
                -H "Content-Type: application/json" \
                -d '{"query":"mutation registerDevice($registerDevice: RegisterDeviceInput!) { registerDevice(registerDevice: $registerDevice) { __typename } }","variables":{"registerDevice":{"applicationRuntime":"android","attributes":{"operatingSystem":"Android","operatingSystemVersion":"13"},"deviceFamily":"android","deviceLanguage":"en","deviceProfile":"phone","devicePlatformId":"android"}},"operationName":"registerDevice"}' 2>/dev/null || true)
            dp_reg=$(jq -r '.extensions.sdk.session.location.countryCode // empty' <<<"$dp_res" 2>/dev/null || true)
            dp_ok=$(jq -r '.extensions.sdk.session.inSupportedLocation // empty' <<<"$dp_res" 2>/dev/null || true)
            if [[ -z "$dp_res" && "$v" == "6" ]]; then
                echo "NoIPv6|N/A" > "$dir/srv_disney"
            elif [[ "$dp_ok" == "true" ]]; then
                echo "Yes|${dp_reg}" > "$dir/srv_disney"
            else
                echo "Block|${dp_reg}" > "$dir/srv_disney"
            fi
        ) &
        (
            local tt_res tt_reg
            tt_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://www.tiktok.com/api/v1/web-cookie-privacy/config?appId=1988" 2>/dev/null || true)
            tt_reg=$(jq -r '.body.appProps.region // empty' <<<"$tt_res" 2>/dev/null || true)
            if [[ -z "$tt_res" && "$v" == "6" ]]; then
                echo "NoIPv6|N/A" > "$dir/srv_tiktok"
            elif [[ -n "$tt_reg" && ! "$tt_reg" =~ ^(RU|BY|CN|IR|KP|IN)$ ]]; then
                echo "Yes|${tt_reg}" > "$dir/srv_tiktok"
            else
                echo "Block|${tt_reg}" > "$dir/srv_tiktok"
            fi
        ) &
        (
            local sp_res sp_reg sp_ok
            sp_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -H "X-Client-Id: 9a8d2f0ce77a4e248bb71fefcb557637" \
                "https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=142b583129b2df829de3656f9eb484e6" 2>/dev/null || true)
            sp_reg=$(jq -r '.country // empty' <<<"$sp_res" 2>/dev/null || true)
            sp_ok=$(jq -r '.is_country_launched // empty' <<<"$sp_res" 2>/dev/null || true)
            [[ "$sp_ok" == "true" ]] && echo "Yes|${sp_reg}" > "$dir/srv_spotify" || echo "Block|${sp_reg}" > "$dir/srv_spotify"
        ) &
        (
            local tw_res tw_reg
            tw_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" "https://gql.twitch.tv/gql" \
                -H "Client-Id: kimne78kx3ncx6brgo4mv6wki5h1ko" -H "Content-Type: application/json" \
                -d '[{"operationName":"VerifyEmail_CurrentUser","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f9e7dcdf7e99c314c82d8f7f725fab5f99d1df3d7359b53c9ae122deec590198"}}}]' 2>/dev/null || true)
            tw_reg=$(jq -r '.[0].data.requestInfo.countryCode // empty' <<<"$tw_res" 2>/dev/null || true)
            if [[ -z "$tw_res" && "$v" == "6" ]]; then
                echo "NoIPv6|N/A" > "$dir/srv_twitch"
            elif [[ -n "$tw_reg" ]]; then
                echo "Yes|${tw_reg}" > "$dir/srv_twitch"
            else
                echo "Block|N/A" > "$dir/srv_twitch"
            fi
        ) &

        # --- AI Services (OpenAI, Claude, Grok, DeepSeek, Qwen, Kimi) ---
        (
            local oa_res oa_code oa_reg=""
            oa_res=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -X POST -H "Statsig-Api-Key: client-zUdXdSTygXJdzoE0sWTkP8GKTVsUMF2IRM7ShVO2JAG" "https://ab.chatgpt.com/v1/initialize" 2>/dev/null || true)
            [[ "$oa_res" =~ \"derived_fields\":\{[^\}]*\"country\":\"([^\"]*)\" ]] && oa_reg="${BASH_REMATCH[1]}"
            oa_code=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.openai.com/v1/models" 2>/dev/null || true)
            [[ "$oa_code" == "401" ]] && echo "Yes|${oa_reg:-OK}" > "$dir/ai_openai" || echo "Block|${oa_reg}" > "$dir/ai_openai"
        ) &
        (
            local cl_res cl_code cl_reg
            cl_res=$(curl -sL "$flag" -m 5 -A "Claude com.anthropic.claude/1.261023.20 (Android 30) Claude/1.261023.20" \
                -H "Anthropic-Client-Platform: android" "https://claude.ai/api/bootstrap" 2>/dev/null || true)
            cl_reg=$(jq -r '.statsig.user.country // empty' <<<"$cl_res" 2>/dev/null || true)
            cl_code=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.anthropic.com/v1/models" 2>/dev/null || true)
            [[ "$cl_code" == "401" ]] && echo "Yes|${cl_reg:-OK}" > "$dir/ai_claude" || echo "Block|${cl_reg}" > "$dir/ai_claude"
        ) &
        (
            local gk_code
            gk_code=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.x.ai/v1/models" 2>/dev/null || true)
            [[ "$gk_code" == "401" ]] && echo "Yes|OK" > "$dir/ai_grok" || echo "Block|N/A" > "$dir/ai_grok"
        ) &
        (
            local ds_code
            ds_code=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.deepseek.com/models" 2>/dev/null || true)
            if [[ "$ds_code" == "000" && "$v" == "6" ]]; then echo "NoIPv6|N/A" > "$dir/ai_deepseek"
            elif [[ "$ds_code" == "401" ]]; then echo "Yes|OK" > "$dir/ai_deepseek"
            else echo "Block|N/A" > "$dir/ai_deepseek"; fi
        ) &
        (
            local qw_code
            qw_code=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models" 2>/dev/null || true)
            if [[ "$qw_code" == "000" && "$v" == "6" ]]; then echo "NoIPv6|N/A" > "$dir/ai_qwen"
            elif [[ "$qw_code" == "401" ]]; then echo "Yes|OK" > "$dir/ai_qwen"
            else echo "Block|N/A" > "$dir/ai_qwen"; fi
        ) &

        # --- Google Search & Outbound Port 25 ---
        (
            local gs_out
            gs_out=$(curl -sL "$flag" -m 5 -A "$UA_BROWSER" -H "Cookie: SOCS=CAI" -w "\nCODE:%{http_code}\nREDIR:%{redirect_url}" "https://www.google.com/search?q=cats" 2>/dev/null || true)
            if [[ "$gs_out" == *"/sorry/"* || "$gs_out" == *"CODE:429"* ]]; then
                echo "Captcha|429" > "$dir/web_google"
            elif [[ "$gs_out" == *"enablejs"* ]]; then
                echo "Clean|200" > "$dir/web_google"
            else
                echo "Block|Err" > "$dir/web_google"
            fi
        ) &
        (
            local mx_addr
            if [[ "$v" == "4" ]]; then
                mx_addr=$(dig +short A gmail-smtp-in.l.google.com 2>/dev/null | head -n1 || true)
            else
                mx_addr=$(dig +short AAAA gmail-smtp-in.l.google.com 2>/dev/null | head -n1 || true)
            fi
            if [[ -n "$mx_addr" ]] && timeout 3 bash -c "</dev/tcp/${mx_addr}/25" &>/dev/null; then
                echo "Open|25" > "$dir/p25"
            else
                echo "Block|25" > "$dir/p25"
            fi
        ) &
    fi
}

# ==============================================================================
# PARSE HELPERS
# ==============================================================================
get_basic_meta() {
    local v="$1" dir="$WORK_DIR/v$1"
    local asn org cc reg_cc city ptr

    asn=$(jq -r '.traits.autonomous_system_number // empty' "$dir/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$asn" || "$asn" == "null" ]] && asn=$(jq -r '.ASN.AutonomousSystemNumber // empty' "$dir/maxmind.json" 2>/dev/null || true)
    [[ -z "$asn" || "$asn" == "null" ]] && asn=$(jq -r '.data.asns[0].asn // empty' "$dir/ripe_asn.json" 2>/dev/null || true)
    [[ -z "$asn" || "$asn" == "null" ]] && asn=$(jq -r '.asn.asn // empty' "$dir/ipapi_is.json" 2>/dev/null || true)

    org=$(jq -r '.traits.autonomous_system_organization // empty' "$dir/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$org" || "$org" == "null" ]] && org=$(jq -r '.ASN.AutonomousSystemOrganization // empty' "$dir/maxmind.json" 2>/dev/null || true)
    [[ -z "$org" || "$org" == "null" ]] && org=$(jq -r '.data.asns[0].holder // empty | sub("^\\S+ (- )?"; "")' "$dir/ripe_asn.json" 2>/dev/null || true)
    [[ -z "$org" || "$org" == "null" ]] && org=$(jq -r '.asn.org // empty' "$dir/ipapi_is.json" 2>/dev/null || true)

    cc=$(jq -r '.country.iso_code // empty' "$dir/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$cc" || "$cc" == "null" ]] && cc=$(jq -r '.Country.IsoCode // empty' "$dir/maxmind.json" 2>/dev/null || true)
    [[ -z "$cc" || "$cc" == "null" ]] && cc=$(jq -r '.location.country_code // empty' "$dir/ipquery.json" 2>/dev/null || true)
    [[ -z "$cc" || "$cc" == "null" ]] && cc=$(jq -r '.countryCode // empty' "$dir/ip_api.json" 2>/dev/null || true)

    reg_cc=$(jq -r '.data.located_resources[0].location // empty' "$dir/ripe_reg.json" 2>/dev/null || true)
    [[ -z "$reg_cc" || "$reg_cc" == "null" ]] && reg_cc="$cc"

    city=$(jq -r '.city.names.en // empty' "$dir/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$city" || "$city" == "null" ]] && city=$(jq -r '.City.Name // empty' "$dir/maxmind.json" 2>/dev/null || true)
    [[ -z "$city" || "$city" == "null" ]] && city=$(jq -r '.location.city // empty' "$dir/ipquery.json" 2>/dev/null || true)

    ptr=$(cat "$dir/ptr.txt" 2>/dev/null || true)
    printf '%s|%s|%s|%s|%s|%s' "${asn:+AS$asn}" "${org:-Unknown}" "${cc:-??}" "${reg_cc:-??}" "${city:-Unknown}" "${ptr:-No PTR}"
}

get_ip_type() {
    local v="$1" db="$2" ip="$3"
    local dir="$WORK_DIR/v${v}"
    [[ ! -d "$dir" ]] && { printf 'N/A'; return; }

    case "$db" in
        maxmind)
            jq_get "$dir/maxmind_direct.json" '.traits.user_type' ;;
        ipinfo)
            jq_get "$dir/ipinfo.json" '.data.asn.type // .data.company.type' ;;
        ipregistry)
            jq_get "$dir/ipregistry.json" '.connection.type // .company.type' ;;
        ipapi)
            jq_get "$dir/ipapi_is.json" '.asn.type // .company.type' ;;
        ipquery)
            if [[ "$(jq_get "$dir/ipquery.json" '.risk.is_datacenter')" == "true" ]]; then printf 'Hosting'
            elif [[ "$(jq_get "$dir/ipquery.json" '.risk.is_mobile')" == "true" ]]; then printf 'Mobile'
            elif jq -e '.isp' "$dir/ipquery.json" &>/dev/null; then printf 'ISP'
            else printf 'N/A'; fi ;;
        ipbase)
            jq_get "$dir/ipbase.json" '.data.connection.type' ;;
        ip2location)
            local u
            u=$(jq_get "$dir/ip2location.json" '.usage_type // .as_info.as_usage_type')
            [[ "$u" == "N/A" && "$(jq_get "$dir/ip2loc_direct.json" '.is_proxy')" == "true" ]] && u="Hosting"
            printf '%s' "$u" ;;
        ipdata)
            local u
            u=$(jq_get "$dir/ipdata.json" '.asn.type // .company.type')
            [[ "$u" == "N/A" && "$(jq_get "$dir/ipdata.json" '.threat.is_datacenter')" == "true" ]] && u="Hosting"
            printf '%s' "$u" ;;
        abuseipdb)
            jq_get "$dir/abuseipdb.json" '.data.usageType' ;;
        proxycheck)
            jq -r --arg ip "$ip" '.[$ip].type // "N/A"' "$dir/proxycheck.json" 2>/dev/null || printf 'N/A' ;;
        ip_api)
            if [[ "$(jq_get "$dir/ip_api.json" '.status')" == "success" ]]; then
                if [[ "$(jq_get "$dir/ip_api.json" '.hosting')" == "true" ]]; then printf 'Hosting'
                elif [[ "$(jq_get "$dir/ip_api.json" '.mobile')" == "true" ]]; then printf 'Mobile'
                else printf 'ISP'; fi
            else printf 'N/A'; fi ;;
        ipwhois)
            local u
            u=$(jq_get "$dir/ipwhois.json" '.connection.type')
            if [[ "$u" == "N/A" && "$(jq_get "$dir/ipwhois.json" '.success')" == "true" ]]; then
                local o
                o=$(jq_get "$dir/ipwhois.json" '.connection.org')
                grep -qiE "host|cloud|server|vps|data|dedi|netcup|hetzner|ovh|digitalocean|linode|vultr|leaseweb|choopa|contabo|pq.hosting|aeza|melbicom|datacamp|m247" <<<"$o" && u="Hosting" || u="ISP"
            fi
            printf '%s' "$u" ;;
        scamalytics)
            local dc
            dc=$(jq_get "$dir/scamalytics.json" '.scamalytics.scamalytics_proxy.is_datacenter')
            if [[ "$dc" == "true" ]]; then printf 'Hosting'
            elif [[ "$dc" == "false" ]]; then printf 'ISP'
            elif [[ -s "$dir/scamalytics.html" ]]; then
                grep -qiE 'Datacenter.*Yes|Server.*Yes' "$dir/scamalytics.html" 2>/dev/null && printf 'Hosting' || printf 'ISP'
            else printf 'N/A'; fi ;;
        dbip)
            local u
            u=$(jq_get "$dir/dbip.json" '.usageType')
            [[ "$u" == "N/A" && "$(jq_get "$dir/dbip.json" '.isHosting')" == "true" ]] && u="Hosting"
            printf '%s' "$u" ;;
    esac
}

get_risk_score() {
    local v="$1" db="$2" ip="$3"
    local dir="$WORK_DIR/v${v}"
    [[ ! -d "$dir" ]] && { printf 'N/A'; return; }

    case "$db" in
        scamalytics)
            local s
            s=$(jq -r '.scamalytics.scamalytics_score // empty' "$dir/scamalytics.json" 2>/dev/null || true)
            if [[ -z "$s" || "$s" == "null" ]] && [[ -s "$dir/scamalytics.html" ]]; then
                s=$(tr '\n' ' ' < "$dir/scamalytics.html" | sed -n 's/.*"score":"\([0-9]*\)".*/\1/p')
                [[ -z "$s" ]] && s=$(grep -i "Fraud Score:" "$dir/scamalytics.html" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
            fi
            printf '%s' "${s:-N/A}" ;;
        ipqs)
            jq_get "$dir/ipqs.json" '.fraud_score' ;;
        ipquery)
            jq_get "$dir/ipquery.json" '.risk.risk_score' ;;
        ip2location)
            jq_get "$dir/ip2location.json" '.fraud_score' ;;
        abuseipdb)
            jq_get "$dir/abuseipdb.json" '.data.abuseConfidenceScore' ;;
        proxycheck)
            jq -r --arg ip "$ip" '.[$ip].risk // "N/A"' "$dir/proxycheck.json" 2>/dev/null || printf 'N/A' ;;
        ipapi)
            local raw
            raw=$(jq -r '.company.abuser_score // .asn.abuser_score // empty' "$dir/ipapi_is.json" 2>/dev/null || true)
            if [[ -n "$raw" && "$raw" != "null" ]]; then
                awk '{printf "%d", $1 * 100}' <<<"$raw"
            else printf 'N/A'; fi ;;
        ipregistry)
            if jq -e '.security' "$dir/ipregistry.json" &>/dev/null; then
                jq -r '.security | ((if .is_tor or .is_tor_exit then 50 else 0 end)+(if .is_attacker then 50 else 0 end)+(if .is_abuser then 40 else 0 end)+(if .is_threat then 40 else 0 end)+(if .is_proxy then 30 else 0 end)+(if .is_vpn then 25 else 0 end)+(if .is_cloud_provider then 15 else 0 end)) | if . > 100 then 100 else . end' "$dir/ipregistry.json" 2>/dev/null || printf 'N/A'
            else printf 'N/A'; fi ;;
        ipdata)
            if jq -e '.threat' "$dir/ipdata.json" &>/dev/null; then
                jq -r '.threat | ((if .is_tor then 50 else 0 end)+(if .is_known_attacker then 50 else 0 end)+(if .is_known_abuser then 40 else 0 end)+(if .is_threat then 40 else 0 end)+(if .is_proxy then 30 else 0 end)+(if .is_vpn then 25 else 0 end)+(if .is_datacenter then 15 else 0 end)) | if . > 100 then 100 else . end' "$dir/ipdata.json" 2>/dev/null || printf 'N/A'
            else printf 'N/A'; fi ;;
        dbip)
            local l
            l=$(jq_get "$dir/dbip.json" '.threatLevel')
            case "$l" in low) printf '0' ;; medium) printf '50' ;; high) printf '100' ;; *) printf 'N/A' ;; esac ;;
    esac
}

get_geoip_cc() {
    local v="$1" db="$2"
    local dir="$WORK_DIR/v${v}"
    [[ ! -d "$dir" ]] && { printf ''; return; }
    local cc=""
    case "$db" in
        MaxMind)       cc=$(jq -r '.country.iso_code // empty' "$dir/maxmind_direct.json" 2>/dev/null || true)
                       [[ -z "$cc" ]] && cc=$(jq -r '.Country.IsoCode // empty' "$dir/maxmind.json" 2>/dev/null || true) ;;
        RIPE)          cc=$(jq -r '.country // empty' "$dir/ripe_rdap.json" 2>/dev/null || true)
                       [[ -z "$cc" ]] && cc=$(jq -r '.data.located_resources[0].location // empty' "$dir/ripe_reg.json" 2>/dev/null || true) ;;
        ipinfo.io)     cc=$(jq -r '.data.country // empty' "$dir/ipinfo.json" 2>/dev/null || true) ;;
        ipregistry.co) cc=$(jq -r '.location.country.code // empty' "$dir/ipregistry.json" 2>/dev/null || true) ;;
        ipapi.is)      cc=$(jq -r '.location.country_code // empty' "$dir/ipapi_is.json" 2>/dev/null || true) ;;
        ipapi.co)      cc=$(jq -r '.country // empty' "$dir/ipapi_co.json" 2>/dev/null || true) ;;
        ip2location)   cc=$(jq -r '.country_code // empty' "$dir/ip2loc_direct.json" 2>/dev/null || true) ;;
        ipdata.co)     cc=$(jq -r '.country_code // empty' "$dir/ipdata.json" 2>/dev/null || true) ;;
        ipbase.com)    cc=$(jq -r '.data.location.country.alpha2 // empty' "$dir/ipbase.json" 2>/dev/null || true) ;;
        ipquery.io)    cc=$(jq -r '.location.country_code // empty' "$dir/ipquery.json" 2>/dev/null || true) ;;
        ipwho.is)      cc=$(jq -r '.country_code // empty' "$dir/ipwhois.json" 2>/dev/null || true) ;;
        ip-api.com)    cc=$(jq -r '.countryCode // empty' "$dir/ip_api.json" 2>/dev/null || true) ;;
        country.is)    cc=$(jq -r '.country // empty' "$dir/country_is.json" 2>/dev/null || true) ;;
        geojs.io)      cc=$(jq -r '.[0].country // .country // empty' "$dir/geojs.json" 2>/dev/null || true) ;;
    esac
    [[ "$cc" =~ ^[A-Z]{2}$ ]] && printf '%s' "$cc"
}

get_security_flag() {
    local v="$1" factor="$2" ip="$3"
    local dir="$WORK_DIR/v${v}"
    [[ ! -d "$dir" ]] && { printf 'N/A'; return; }

    case "$factor" in
        datacenter)
            local a b c d
            a=$(jq_get "$dir/ipapi_is.json" '.is_datacenter')
            b=$(jq_get "$dir/ipquery.json" '.risk.is_datacenter')
            c=$(jq_get "$dir/ip_api.json" '.hosting')
            d=$(jq_get "$dir/ipregistry.json" '.security.is_cloud_provider')
            [[ "$a $b $c $d" == *"true"* ]] && printf 'true' || printf 'false' ;;
        vpn)
            local a b c
            a=$(jq_get "$dir/ipapi_is.json" '.is_vpn')
            b=$(jq_get "$dir/ipquery.json" '.risk.is_vpn')
            c=$(jq_get "$dir/ipregistry.json" '.security.is_vpn')
            [[ "$a $b $c" == *"true"* ]] && printf 'true' || printf 'false' ;;
        proxy)
            local a b c d
            a=$(jq_get "$dir/ipapi_is.json" '.is_proxy')
            b=$(jq_get "$dir/ipquery.json" '.risk.is_proxy')
            c=$(jq_get "$dir/ip_api.json" '.proxy')
            d=$(jq -r --arg ip "$ip" '.[$ip].proxy // "no"' "$dir/proxycheck.json" 2>/dev/null || true)
            [[ "$a $b $c $d" =~ (true|yes) ]] && printf 'true' || printf 'false' ;;
        tor)
            local a b c
            a=$(jq_get "$dir/ipapi_is.json" '.is_tor')
            b=$(jq_get "$dir/ipquery.json" '.risk.is_tor')
            c=$(jq_get "$dir/ipregistry.json" '.security.is_tor')
            [[ "$a $b $c" == *"true"* ]] && printf 'true' || printf 'false' ;;
        abuser)
            local a b c
            a=$(jq_get "$dir/ipapi_is.json" '.is_abuser')
            b=$(jq_get "$dir/ipregistry.json" '.security.is_abuser')
            c=$(jq_get "$dir/ipdata.json" '.threat.is_known_abuser')
            [[ "$a $b $c" == *"true"* ]] && printf 'true' || printf 'false' ;;
        crawler)
            local a b
            a=$(jq_get "$dir/ipapi_is.json" '.is_crawler')
            b=$(jq_get "$dir/ipregistry.json" '.security.is_attacker')
            [[ "$a $b" == *"true"* ]] && printf 'true' || printf 'false' ;;
    esac
}

# ==============================================================================
# BUILD CARDS & SECTIONS
# ==============================================================================
build_ip_type_card() {
    local dual="$1"
    local name_w=14 col_w=11
    if ((dual == 1)); then
        printf '%s%s%s\n' "$(paint "$C_DIM" "$(pad "Database" "$name_w")")" "$(paint "$C_DIM" "$(pad "IPv4" "$col_w")")" "$(paint "$C_DIM" "$(pad "IPv6" "$col_w")")"
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        printf '%s%s\n' "$(paint "$C_DIM" "$(pad "Database" "$name_w")")" "$(paint "$C_DIM" "$(pad "$lbl" "$col_w")")"
    fi

    local item db label t4 t6
    for item in \
        "maxmind|MaxMind" \
        "ipinfo|ipinfo.io" \
        "ipregistry|ipregistry.co" \
        "ipapi|ipapi.is" \
        "ipquery|ipquery.io" \
        "ipbase|ipbase.com" \
        "ip2location|IP2Location" \
        "ipdata|ipdata.co" \
        "abuseipdb|AbuseIPDB" \
        "proxycheck|ProxyCheck.io" \
        "ip_api|ip-api.com" \
        "ipwhois|ipwho.is" \
        "scamalytics|Scamalytics" \
        "dbip|db-ip.com"; do
        IFS='|' read -r db label <<<"$item"
        if ((dual == 1)); then
            t4=$(get_ip_type 4 "$db" "$IPV4_ADDR")
            t6=$(get_ip_type 6 "$db" "$IPV6_ADDR")
            printf '%s%s%s\n' "$(pad "$label" "$name_w")" "$(format_type_cell "$t4" "$col_w")" "$(format_type_cell "$t6" "$col_w")"
        elif [[ -n "$IPV4_ADDR" ]]; then
            t4=$(get_ip_type 4 "$db" "$IPV4_ADDR")
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_type_cell "$t4" "$col_w")"
        else
            t6=$(get_ip_type 6 "$db" "$IPV6_ADDR")
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_type_cell "$t6" "$col_w")"
        fi
    done
}

build_risk_score_card() {
    local dual="$1"
    local name_w=14 col_w=11
    if ((dual == 1)); then
        printf '%s%s%s\n' "$(paint "$C_DIM" "$(pad "Engine" "$name_w")")" "$(paint "$C_DIM" "$(pad "IPv4" "$col_w")")" "$(paint "$C_DIM" "$(pad "IPv6" "$col_w")")"
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        printf '%s%s\n' "$(paint "$C_DIM" "$(pad "Engine" "$name_w")")" "$(paint "$C_DIM" "$(pad "$lbl" "$col_w")")"
    fi

    local item db label sfx s4 s6
    for item in \
        "scamalytics|Scamalytics|" \
        "ipqs|IPQS|" \
        "ipquery|ipquery.io|" \
        "ip2location|IP2Location|" \
        "abuseipdb|AbuseIPDB|" \
        "proxycheck|ProxyCheck.io|" \
        "ipapi|ipapi.is|%" \
        "ipregistry|ipregistry.co|" \
        "ipdata|ipdata.co|" \
        "dbip|db-ip.com|%"; do
        IFS='|' read -r db label sfx <<<"$item"
        if ((dual == 1)); then
            s4=$(get_risk_score 4 "$db" "$IPV4_ADDR")
            s6=$(get_risk_score 6 "$db" "$IPV6_ADDR")
            printf '%s%s%s\n' "$(pad "$label" "$name_w")" "$(format_score_cell "$s4" "$col_w" "$sfx")" "$(format_score_cell "$s6" "$col_w" "$sfx")"
        elif [[ -n "$IPV4_ADDR" ]]; then
            s4=$(get_risk_score 4 "$db" "$IPV4_ADDR")
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_score_cell "$s4" "$col_w" "$sfx")"
        else
            s6=$(get_risk_score 6 "$db" "$IPV6_ADDR")
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_score_cell "$s6" "$col_w" "$sfx")"
        fi
    done
}

build_factors_card() {
    local dual="$1"
    local name_w=14 col_w=11
    if ((dual == 1)); then
        printf '%s%s%s\n' "$(paint "$C_DIM" "$(pad "Factor" "$name_w")")" "$(paint "$C_DIM" "$(pad "IPv4" "$col_w")")" "$(paint "$C_DIM" "$(pad "IPv6" "$col_w")")"
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        printf '%s%s\n' "$(paint "$C_DIM" "$(pad "Factor" "$name_w")")" "$(paint "$C_DIM" "$(pad "$lbl" "$col_w")")"
    fi

    local item key label f4 f6
    for item in \
        "datacenter|Datacenter" \
        "vpn|VPN" \
        "proxy|Proxy" \
        "tor|Tor Exit" \
        "abuser|Abuser / Spam" \
        "crawler|Bot / Scanner"; do
        IFS='|' read -r key label <<<"$item"
        if ((dual == 1)); then
            f4=$(get_security_flag 4 "$key" "$IPV4_ADDR")
            f6=$(get_security_flag 6 "$key" "$IPV6_ADDR")
            printf '%s%s%s\n' "$(pad "$label" "$name_w")" "$(format_bool_cell "$f4" "$col_w")" "$(format_bool_cell "$f6" "$col_w")"
        elif [[ -n "$IPV4_ADDR" ]]; then
            f4=$(get_security_flag 4 "$key" "$IPV4_ADDR")
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_bool_cell "$f4" "$col_w")"
        else
            f6=$(get_security_flag 6 "$key" "$IPV6_ADDR")
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_bool_cell "$f6" "$col_w")"
        fi
    done
}

build_dnsbl_mail_card() {
    local dual="$1"
    local name_w=14 col_w=11
    if ((dual == 1)); then
        printf '%s%s%s\n' "$(paint "$C_DIM" "$(pad "Check" "$name_w")")" "$(paint "$C_DIM" "$(pad "IPv4" "$col_w")")" "$(paint "$C_DIM" "$(pad "IPv6" "$col_w")")"
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        printf '%s%s\n' "$(paint "$C_DIM" "$(pad "Check" "$name_w")")" "$(paint "$C_DIM" "$(pad "$lbl" "$col_w")")"
    fi

    local c4=0 c6=0 cell4 cell6
    [[ -d "$WORK_DIR/v4/rbl" ]] && c4=$(find "$WORK_DIR/v4/rbl" -type f | wc -l)
    [[ -d "$WORK_DIR/v6/rbl" ]] && c6=$(find "$WORK_DIR/v6/rbl" -type f | wc -l)
    ((c4 == 0)) && cell4=$(paint "$C_YES" "$(pad "✓ 0/10" "$col_w")") || cell4=$(paint "$C_NO" "$(pad "✗ ${c4}/10" "$col_w")")
    ((c6 == 0)) && cell6=$(paint "$C_YES" "$(pad "✓ 0/10" "$col_w")") || cell6=$(paint "$C_NO" "$(pad "✗ ${c6}/10" "$col_w")")

    if ((dual == 1)); then
        printf '%s%s%s\n' "$(pad "DNSBL (10 RBL)" "$name_w")" "$cell4" "$cell6"
    elif [[ -n "$IPV4_ADDR" ]]; then
        printf '%s%s\n' "$(pad "DNSBL (10 RBL)" "$name_w")" "$cell4"
    else
        printf '%s%s\n' "$(pad "DNSBL (10 RBL)" "$name_w")" "$cell6"
    fi

    if ((IS_LOCAL_IP == 1)); then
        local item file label v4s v6s
        for item in \
            "p25|Port 25 SMTP" \
            "web_google|Google Search"; do
            IFS='|' read -r file label <<<"$item"
            if ((dual == 1)); then
                v4s=$(cat "$WORK_DIR/v4/$file" 2>/dev/null || true)
                v6s=$(cat "$WORK_DIR/v6/$file" 2>/dev/null || true)
                printf '%s%s%s\n' "$(pad "$label" "$name_w")" "$(format_srv_cell "$v4s" "$col_w")" "$(format_srv_cell "$v6s" "$col_w")"
            elif [[ -n "$IPV4_ADDR" ]]; then
                v4s=$(cat "$WORK_DIR/v4/$file" 2>/dev/null || true)
                printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_srv_cell "$v4s" "$col_w")"
            else
                v6s=$(cat "$WORK_DIR/v6/$file" 2>/dev/null || true)
                printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_srv_cell "$v6s" "$col_w")"
            fi
        done
    fi
}

build_platforms_card() {
    local dual="$1"
    local name_w=14 col_w=11
    if ((dual == 1)); then
        printf '%s%s%s\n' "$(paint "$C_DIM" "$(pad "Platform" "$name_w")")" "$(paint "$C_DIM" "$(pad "IPv4" "$col_w")")" "$(paint "$C_DIM" "$(pad "IPv6" "$col_w")")"
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        printf '%s%s\n' "$(paint "$C_DIM" "$(pad "Platform" "$name_w")")" "$(paint "$C_DIM" "$(pad "$lbl" "$col_w")")"
    fi

    local item file label v4c v6c
    for item in \
        "plat_google|Google" \
        "plat_steam|Steam" \
        "plat_playstation|PlayStation" \
        "plat_apple|Apple" \
        "plat_microsoft|Microsoft" \
        "plat_reddit|Reddit" \
        "plat_ookla|Ookla Speed" \
        "plat_jetbrains|JetBrains"; do
        IFS='|' read -r file label <<<"$item"
        if ((dual == 1)); then
            v4c=$(cat "$WORK_DIR/v4/$file" 2>/dev/null || true)
            v6c=$(cat "$WORK_DIR/v6/$file" 2>/dev/null || true)
            printf '%s%s%s\n' "$(pad "$label" "$name_w")" "$(format_cc_cell "$v4c" "$col_w")" "$(format_cc_cell "$v6c" "$col_w")"
        elif [[ -n "$IPV4_ADDR" ]]; then
            v4c=$(cat "$WORK_DIR/v4/$file" 2>/dev/null || true)
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_cc_cell "$v4c" "$col_w")"
        else
            v6c=$(cat "$WORK_DIR/v6/$file" 2>/dev/null || true)
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_cc_cell "$v6c" "$col_w")"
        fi
    done
}

build_services_card() {
    local dual="$1" shift_list="$2"
    local name_w=14 col_w=11
    if ((dual == 1)); then
        printf '%s%s%s\n' "$(paint "$C_DIM" "$(pad "Service" "$name_w")")" "$(paint "$C_DIM" "$(pad "IPv4" "$col_w")")" "$(paint "$C_DIM" "$(pad "IPv6" "$col_w")")"
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        printf '%s%s\n' "$(paint "$C_DIM" "$(pad "Service" "$name_w")")" "$(paint "$C_DIM" "$(pad "$lbl" "$col_w")")"
    fi

    local item file label v4s v6s
    for item in $shift_list; do
        IFS='|' read -r file label <<<"$item"
        if ((dual == 1)); then
            v4s=$(cat "$WORK_DIR/v4/$file" 2>/dev/null || true)
            v6s=$(cat "$WORK_DIR/v6/$file" 2>/dev/null || true)
            printf '%s%s%s\n' "$(pad "$label" "$name_w")" "$(format_srv_cell "$v4s" "$col_w")" "$(format_srv_cell "$v6s" "$col_w")"
        elif [[ -n "$IPV4_ADDR" ]]; then
            v4s=$(cat "$WORK_DIR/v4/$file" 2>/dev/null || true)
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_srv_cell "$v4s" "$col_w")"
        else
            v6s=$(cat "$WORK_DIR/v6/$file" 2>/dev/null || true)
            printf '%s%s\n' "$(pad "$label" "$name_w")" "$(format_srv_cell "$v6s" "$col_w")"
        fi
    done
}

print_geoip_card() {
    local dual="$1"
    local dbs=(MaxMind RIPE ipinfo.io ipregistry.co ipapi.is ipapi.co ip2location ipdata.co ipbase.com ipquery.io ipwho.is ip-api.com country.is geojs.io)
    local total=0 agree=0
    local -A dev4=() dev6=()

    local db c4 c6 ok
    for db in "${dbs[@]}"; do
        c4=""; c6=""; ok=0
        [[ -n "$IPV4_ADDR" ]] && c4=$(get_geoip_cc 4 "$db")
        [[ -n "$IPV6_ADDR" ]] && c6=$(get_geoip_cc 6 "$db")
        if [[ -n "$c4" || -n "$c6" ]]; then
            total=$((total + 1))
            ok=1
            if [[ -n "$c4" && "$c4" != "$VERDICT_CC" ]]; then
                ok=0; dev4[$c4]+="${dev4[$c4]:+, }$db"
            fi
            if [[ -n "$c6" && "$c6" != "$VERDICT_CC" ]]; then
                ok=0; dev6[$c6]+="${dev6[$c6]:+, }$db"
            fi
            ((ok == 1)) && agree=$((agree + 1))
        fi
    done

    ((total == 0)) && return
    local bar_w=$((FULL_CARD_WIDTH - 4))
    local filled=$((bar_w * agree / total))
    local bar_str
    bar_str="$(paint "$C_BAR" "$(repeat_char "$SUMMARY_BAR_CHAR" "$filled")")$(paint "$C_DIM" "$(repeat_char "$SUMMARY_BAR_REST_CHAR" $((bar_w - filled)))")"

    local summary
    summary="$(paint "$C_VALUE" "$VERDICT_CC") $(paint "$C_DIM" "${agree}/${total}")"

    {
        printf '%s\n' "$bar_str"
        if ((agree == total)); then
            printf '%s\n' "$(paint "$C_YES" "✓ every GeoIP database agrees ($VERDICT_CC)")"
        else
            local cc
            for cc in "${!dev4[@]}"; do
                printf '%s %s %s\n' "$(paint "$C_WARN" "$(pad "$cc" 4)")" "$(pad "${dev4[$cc]}" $((bar_w - 8)))" "$(paint "$C_DIM" "v4")"
            done
            for cc in "${!dev6[@]}"; do
                printf '%s %s %s\n' "$(paint "$C_WARN" "$(pad "$cc" 4)")" "$(pad "${dev6[$cc]}" $((bar_w - 8)))" "$(paint "$C_DIM" "v6")"
            done
        fi
    } | render_card "GeoIP" "$FULL_CARD_WIDTH" 0 "$summary"
    printf '\n'
}

# --- vernette-style CDN Block (with Vertical Bar ┃, Country & Nodes v4 · v6) ---
print_cdn_section() {
    local dual="$1"
    ((IS_LOCAL_IP == 0)) && return

    local name_w=19 cell_w=8
    local -a rows=()
    rows+=("$(paint "$C_TITLE" "CDN")")

    if ((dual == 1)); then
        rows+=("$(paint "$C_DIM" "$(pad "Service" "$name_w")$(pad "IPv4" "$cell_w")$(pad "IPv6" "$cell_w")   Node")")
    else
        local lbl="IPv4"; [[ -z "$IPV4_ADDR" ]] && lbl="IPv6"
        rows+=("$(paint "$C_DIM" "$(pad "Service" "$name_w")$(pad "$lbl" "$cell_w")   Node")")
    fi

    local item file label c4 n4 c6 n6
    for item in \
        "cdn_cloudflare|Cloudflare" \
        "cdn_youtube|YouTube" \
        "cdn_netflix|Netflix" \
        "cdn_fastly|Fastly" \
        "cdn_cloudfront|CloudFront" \
        "cdn_bunny|BunnyCDN"; do
        IFS='|' read -r file label <<<"$item"
        IFS='|' read -r c4 n4 <<<"$(cat "$WORK_DIR/v4/$file" 2>/dev/null || echo "-|-")"
        IFS='|' read -r c6 n6 <<<"$(cat "$WORK_DIR/v6/$file" 2>/dev/null || echo "-|-")"

        local cc4_str cc6_str n4_str n6_str
        [[ "$c4" =~ ^[A-Z]{2}$ ]] && cc4_str=$(paint "$C_VALUE" "$(pad "$c4" "$cell_w")") || cc4_str=$(paint "$C_DIM" "$(pad "${c4:--}" "$cell_w")")
        [[ "$c6" =~ ^[A-Z]{2}$ ]] && cc6_str=$(paint "$C_VALUE" "$(pad "$c6" "$cell_w")") || cc6_str=$(paint "$C_DIM" "$(pad "${c6:--}" "$cell_w")")
        [[ -n "$n4" && "$n4" != "-" ]] && n4_str=$(paint "$C_VALUE" "$n4") || n4_str=$(paint "$C_DIM" "?")
        [[ -n "$n6" && "$n6" != "-" ]] && n6_str=$(paint "$C_VALUE" "$n6") || n6_str=$(paint "$C_DIM" "?")

        if ((dual == 1)); then
            rows+=("$(pad "$label" "$name_w")${cc4_str}${cc6_str}   ${n4_str} $(paint "$C_DIM" "·") ${n6_str}")
        elif [[ -n "$IPV4_ADDR" ]]; then
            rows+=("$(pad "$label" "$name_w")${cc4_str}   ${n4_str}")
        else
            rows+=("$(pad "$label" "$name_w")${cc6_str}   ${n6_str}")
        fi
    done

    printf '%s\n' "${rows[@]}" | print_bar_block
}

print_header_bar() {
    local disp_v4="$IPV4_ADDR" disp_v6="$IPV6_ADDR"
    if [[ "$MASK_IP" == true ]]; then
        [[ -n "$disp_v4" ]] && disp_v4="${disp_v4%.*.*}.*.*"
        [[ -n "$disp_v6" ]] && disp_v6="${disp_v6%%:*}:${disp_v6#*:}" && disp_v6="${disp_v6%%:*}::*"
    fi

    local -a lines=()
    lines+=("$(paint "$C_DIM" "IPQuality · Dual-Stack Diagnostics · $(date -u +"%Y-%m-%d %H:%M UTC")")")
    lines+=("")

    if [[ -n "$IPV4_ADDR" ]]; then
        IFS='|' read -r asn org cc reg_cc city ptr <<<"$(get_basic_meta 4)"
        VERDICT_CC="$cc"
        lines+=("$(pad "IPv4" 6)$(paint "$C_VALUE" "$(pad "$disp_v4" 20)")  $(pad "${asn} ${org}" 34) $(paint "$C_DIM" "registered in") $(paint "$C_VALUE" "$reg_cc")")
        lines+=("$(pad "" 6)$(paint "$C_DIM" "Location: ${city}, ${cc} · PTR: ${ptr}")")
    fi

    if [[ -n "$IPV6_ADDR" ]]; then
        IFS='|' read -r asn org cc reg_cc city ptr <<<"$(get_basic_meta 6)"
        [[ -z "$VERDICT_CC" || "$VERDICT_CC" == "??" ]] && VERDICT_CC="$cc"
        lines+=("$(pad "IPv6" 6)$(paint "$C_VALUE" "$disp_v6")")
        lines+=("$(pad "" 6)$(pad "${asn} ${org}" 34) $(paint "$C_DIM" "Location: ${city}, ${cc} · registered in") $(paint "$C_VALUE" "$reg_cc")")
        lines+=("$(pad "" 6)$(paint "$C_DIM" "PTR: ${ptr}")")
    fi

    if [[ -n "$VERDICT_CC" && "$VERDICT_CC" != "??" ]]; then
        lines+=("")
        lines+=("$(paint "$C_BADGE" " $VERDICT_CC ")  $(paint "$C_VALUE" "Primary GeoIP Region")  $(paint "$C_DIM" "seen by most services")")
    fi

    printf '\n'
    printf '%s\n' "${lines[@]}" | print_bar_block
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
check_deps

# Pre-fetch MaxMind official demo token in background (like vernette/ipregion)
(
    mm_page=$(curl -sLm 4 -A "$UA_BROWSER" -c "$WORK_DIR/mm_cookies" "https://www.maxmind.com/en/geoip-web-services-demo" 2>/dev/null || true)
    if [[ "$mm_page" =~ value=\"([0-9a-f]+)\"\ name=\"csrf_token\" ]]; then
        csrf="${BASH_REMATCH[1]}"
        curl -sLm 4 -A "$UA_BROWSER" -X POST -b "$WORK_DIR/mm_cookies" -H "X-CSRF-Token: $csrf" \
            "https://www.maxmind.com/en/geoip2/demo/token" 2>/dev/null | jq -r '.token // empty' > "$WORK_DIR/mm_token" 2>/dev/null || true
    fi
) &

if [[ -n "$CUSTOM_IP" ]]; then
    IS_LOCAL_IP=0
    if [[ "$CUSTOM_IP" == *":"* ]]; then
        IPV6_ADDR="$CUSTOM_IP"
    else
        IPV4_ADDR="$CUSTOM_IP"
    fi
    wait_with_progress "Preparing session"
else
    if [[ "$STACK_MODE" == "dual" || "$STACK_MODE" == "4" ]]; then
        (curl -s4m 4 "https://ipv4.icanhazip.com" 2>/dev/null || curl -s4m 4 "https://api.ipify.org" 2>/dev/null) | tr -d '[:space:]' > "$WORK_DIR/ip4" &
    fi
    if [[ "$STACK_MODE" == "dual" || "$STACK_MODE" == "6" ]]; then
        (curl -s6m 4 "https://ipv6.icanhazip.com" 2>/dev/null || curl -s6m 4 "https://api6.ipify.org" 2>/dev/null) | tr -d '[:space:]' > "$WORK_DIR/ip6" &
    fi
    wait_with_progress "Detecting IP addresses"
    [[ -s "$WORK_DIR/ip4" ]] && IPV4_ADDR=$(<"$WORK_DIR/ip4")
    [[ -s "$WORK_DIR/ip6" ]] && IPV6_ADDR=$(<"$WORK_DIR/ip6")
fi

if [[ -z "$IPV4_ADDR" && -z "$IPV6_ADDR" ]]; then
    printf '%sError:%s Could not detect public IPv4 or IPv6 address.\n' "$C_NO" "$C_RESET" >&2
    exit 1
fi

[[ -n "$IPV4_ADDR" ]] && collect_stack_data 4 "$IPV4_ADDR"
[[ -n "$IPV6_ADDR" ]] && collect_stack_data 6 "$IPV6_ADDR"
wait_with_progress "Checking IP quality"

IS_DUAL=0
[[ -n "$IPV4_ADDR" && -n "$IPV6_ADDR" ]] && IS_DUAL=1

print_header_bar

# Row 1: IP Type (14 DBs) + Risk Score (10 Engines)
T_CARD=$(build_ip_type_card "$IS_DUAL")
S_CARD=$(build_risk_score_card "$IS_DUAL")
render_card_pair "IP Type" "Risk Score" "$T_CARD" "$S_CARD" "14 DBs" "10 Engines"
printf '\n'

# Row 2: Security Factors + DNSBL & Mail/Web
F_CARD=$(build_factors_card "$IS_DUAL")
D_CARD=$(build_dnsbl_mail_card "$IS_DUAL")
render_card_pair "Security Factors" "DNSBL & Connectivity" "$F_CARD" "$D_CARD"
printf '\n'

# Row 3: Platforms & Streaming + AI Services (only for local IP)
if ((IS_LOCAL_IP == 1)); then
    P_CARD=$(build_platforms_card "$IS_DUAL")
    STR_AI_LIST="srv_youtube|YouTube srv_netflix|Netflix srv_disney|Disney+ srv_tiktok|TikTok srv_spotify|Spotify srv_twitch|Twitch ai_openai|ChatGPT/OpenAI ai_claude|Claude ai_gemini|Google Gemini ai_grok|xAI Grok ai_deepseek|DeepSeek ai_qwen|Alibaba Qwen"
    SA_CARD=$(build_services_card "$IS_DUAL" "$STR_AI_LIST")
    render_card_pair "Platforms Geo" "Streaming & AI" "$P_CARD" "$SA_CARD"
    printf '\n'
fi

# Row 4: GeoIP Consensus Bar (14 DBs)
print_geoip_card "$IS_DUAL"

# Row 5: vernette-style CDN Block (6 CDNs with Country + Nodes v4 · v6)
print_cdn_section "$IS_DUAL"

printf '   %s %s  ·  %s %s  ·  %s %s  ·  %s %s\n\n' \
    "$(paint "$C_YES" "✓")" "$(paint "$C_DIM" "clean / ISP")" \
    "$(paint "$C_WARN" "⚠")" "$(paint "$C_DIM" "business / elevated")" \
    "$(paint "$C_NO" "✗")" "$(paint "$C_DIM" "hosting / blocked")" \
    "$(paint "$C_DIM" "-")" "$(paint "$C_DIM" "no IPv6")"
