#!/bin/bash
#
# megaupload-dl: Download a file from Megaupload (free download, no account 
# required) with automatic captcha recognition. 
#
# Documentation: http://code.google.com/p/tokland/wiki/MegauploadDownloader
# Author: (2010) Arnau Sanchez <tokland@gmail.com>

EXIT_STATUSES=(
  [0]=ok            
  [1]=unknown_link
  [2]=arguments
  [3]=link_dead
  [4]=link_problem
  [5]=ocr
  [6]=parse
  [7]=password_required
  [8]=password_error
  [100]=network
  [101]=temporally_unavailable
  [110]=runtime
)

# Echo a message to stderr
stderr() { echo -e "$@" >&2; }

# Echo an info message to stderr
info() { stderr "--- $@"; }

# Check if regular expression $1 matches string $2
match() { grep -q "$1" <<< "$2"; }

# Get first line that matches regular expression $1 and parse string $2
parse() { local S=$(sed -n "/$1/ s/^.*$2.*$/\1/p" | head -n1) && test "$S" && echo "$S"; }

# Parse form input value from its name ($1)
parse_form_input() { parse "name=\"$1\"" 'value="\([^"]*\)'; }

# Show image using ASCII characters 
show_ascii_image() {
  aview --version &>/dev/null || 
    { info "Install package aview to see the captcha"; return 0; } 
  convert "$1" -negate -depth 8 pnm:- |
    aview -width 60 -height 20 -kbddriver stdin <(cat) 2>/dev/null <<< "q" |
    sed -e '1d;/\x0C/,/\x0C/d' | grep -v "^[[:space:]]*$"
}

# OCR: convert image to text
ocr() {
  local TIFF=$(tempfile --suffix=".tif")
  local TEXT=$(tempfile --suffix=".txt")
  convert - tif:- > $TIFF
  show_ascii_image $TIFF | while read LINE; do
    info "$LINE"
  done
  tesseract $TIFF ${TEXT/%.txt}
  cat $TEXT
  rm -f $TIFF $TEXT
}

# Print an error with key $1 (see EXIT_STATUSES) and message $2. 
# Return numeric status code
error() {
  local KEY=$1; local MSG=$2 
  for SC in ${!EXIT_STATUSES[@]}; do
    if test "${EXIT_STATUSES[$SC]}" = "$KEY"; then
      stderr "ERROR [$KEY]: $MSG"
      echo $SC
      return
    fi 
  done
  stderr "ERROR [runtime]: unknown error key: $KEY ($MSG)"
  echo 255
}

check_link_problems() {
  local MSG=$(echo "$1" | parse 'middle.*color:#FF6700;' '<center>\(.*\)<' 2>/dev/null) || true
  match "temporarily unavailable" "$MSG" &&
    return $(error temporally_unavailable "File is temporarily unavailable")
  test "$MSG" && return $(error link_problem "server says: '$MSG'")
  return 0
}

# Download a Megaupload link ($1) and return download file path with optional password ($2) 
megaupload_download() {
  URL=$1
  PASSWORD=$2
  match "^\(http://\)\?\(www\.\)\?megaupload.com/" "$URL" ||
    return $(error unknown_link "this does not seem a megaupload link: $URL")
  
  while true; do 
    info "GET $URL"
    PAGE=$(curl -s $URL) || 
      return $(error network "downloading main page")
    match "the link you have clicked is not available" "$PAGE" && 
      return $(error link_dead "Link is dead")
    check_link_problems "$PAGE" || return $?
    PASSRE='name="filepassword"'
    if match "$PASSRE" "$PAGE"; then
      test "$PASSWORD" || return $(error password_required "No password provided")
      info "POST $URL (filepassword=$PASSWORD)"
      WAITPAGE=$(curl -F "filepassword=$PASSWORD" "$URL") ||
        return $(error network "posting password form")
      match "$PASSRE" "$WAITPAGE" && return $(error password_error "Password error")
      check_link_problems "$WAITPAGE" || return $?
    else 
      CAPTCHACODE=$(echo "$PAGE" | parse_form_input captchacode) ||
        return $(error parse "captchacode field")
      MEGAVAR=$(echo "$PAGE" | parse_form_input megavar) ||
        return $(error parse "megavar field")      
      CAPTCHA_URL=$(echo "$PAGE" | parse "gencap.php" 'img src="\([^"]*\)') ||
        return $(error parse "captcha image")
      info "GET $CAPTCHA_URL"
      CAPTCHA_IMG=$(tempfile) 
      curl -s -o "$CAPTCHA_IMG" "$CAPTCHA_URL" || 
        return $(error network "getting captcha image")
      CAPTCHA=$(convert "$CAPTCHA_IMG" +matte gif:- | ocr | head -n1 | tr -d -c "[0-9a-zA-Z]") || {
        rm -f "$CAPTCHA_IMG"
        return $(error ocr "imagemagick/tesseract installed?") 
      }
      rm -f "$CAPTCHA_IMG"
      info "POST $URL (captcha=$CAPTCHA)"
      WAITPAGE=$(curl -s -F "captchacode=$CAPTCHACODE" -F "megavar=$MEGAVAR" \
                         -F "captcha=$CAPTCHA" "$URL") ||
        return $(error network "posting captcha form")
    fi
    WAITTIME=$(echo "$WAITPAGE" | parse "^[[:space:]]*count=" \
                                        "count=\([[:digit:]]\+\);" 2>/dev/null) ||
      { info "Wait time not found in response (wrong captcha?), retrying"; continue; }
    FILEURL=$(echo "$WAITPAGE" | parse 'id="downloadlink"' 'href="\([^"]*\)"') ||
      return $(error parse "download link not found")
    FILENAME=$(basename "$FILEURL" | { recode html..utf8 || cat; })
    info "Waiting $WAITTIME seconds before starting download"
    sleep $WAITTIME
    info "GET $FILEURL"
    HTTP_CODE=$(curl -w "%{http_code}" --globoff -o "$FILENAME" "$FILEURL") ||
      return $(error network "getting file")
    if ! match "2.." "$HTTP_CODE"; then
      info "unsuccessful HTTP code: $HTTP_CODE"
      grep -iq "limit exceeded" "$FILENAME" ||
        return $(error parsing "unsuccessful http_code ($HTTP_CODE) but no limit message found")
      MINUTES=$(<"$FILENAME" parse "url=" "url=\([^\"]*\)" | xargs -r curl -s | 
                parse "Please wait" "wait \([[:digit:]]\+\) min") || true
      if test "$MINUTES"; then 
        info "Download limit exceeded: waiting $MINUTES minutes by server request"
        sleep $((MINUTES*60))
      else
        info "No wait time found, let's wait 10 minutes before retrying"
        sleep 600
      fi
      continue
    fi
    echo "$FILENAME"
    break
  done
}

# Main
if ! match "bash" "$0"; then
  set -e -u -o pipefail
  if test $# -ne 1; then
    stderr "Usage: $(basename $0) MEGAUPLOAD_URL[@PASSWORD]\n"
    stderr "  Download a Megaupload file (path is written to stdout)"
    exit 1
  fi  
  IFS="@" read URL PASSWORD <<< "$1"
  megaupload_download "$URL" "$PASSWORD" 
fi