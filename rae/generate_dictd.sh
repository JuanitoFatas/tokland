#!/bin/bash
set -e

remove_html_tags() { sed "s/<[^>]*>//g"; }
remove_blank_lines() { 
  sed "s/^[[:space:]]\+$//" | 
    sed '/./,$!d' | 
    sed ':a;/^\n*$/{$d;N;ba;}'
} 

generate_jargon_input() {
  local DIRECTORY=$1
  
  find "$DIRECTORY" -type f -name '*.html' | while read HTMLFILE; do
    WORD=$(basename "$HTMLFILE" ".html")
    DEFINITION=$(cat "$HTMLFILE" | grep -v "<title" | remove_html_tags | remove_blank_lines)
    # Jargon (-f) format 
    echo ":$WORD:$DEFINITION"
  done
}

generate_dict() {
  local DIRECTORY=$1
  local NAME=$2  
  
  generate_jargon_input "$DIRECTORY" | 
    dictfmt -j --utf8 --without-headword -s "$NAME" "$NAME"
  dictzip $NAME.dict
  echo "$NAME.index $NAME.dict.dz"
}

generate_dict "html-defs" "drae"
