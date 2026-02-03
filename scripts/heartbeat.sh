#!/bin/bash
# ~/workspace/FULBOT/scripts/heartbeat.sh
# Moltbook UL Hiking Gear Bot - Heartbeat Script
#
# This script checks Moltbook periodically and uses Gemini AI to generate responses.
# Run manually: bash ~/workspace/FULBOT/scripts/heartbeat.sh

set -e

# Configuration
MOLTBOT_DIR="$HOME/workspace/FULBOT"
STATE_FILE="$HOME/.config/moltbook/state.json"
SKILLS_DIR="$MOLTBOT_DIR/skills/moltbook"
DATA_DIR="$MOLTBOT_DIR/data"
CONFIG_DIR="$MOLTBOT_DIR/config"
COOLDOWN_SECONDS=14400  # 4 hours

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Ensure directories exist
mkdir -p "$SKILLS_DIR" "$DATA_DIR" "$CONFIG_DIR" "$(dirname "$STATE_FILE")"

# Source API keys
if [ -f "$CONFIG_DIR/.env" ]; then
    source "$CONFIG_DIR/.env"
else
    log_error "Config file not found: $CONFIG_DIR/.env"
    log_info "Please create the config file with your API keys."
    exit 1
fi

# Validate API keys
if [ -z "$MOLTBOOK_API_KEY" ] || [ "$MOLTBOOK_API_KEY" = "your_moltbook_key_here" ]; then
    log_error "MOLTBOOK_API_KEY is not set or is still the placeholder value."
    log_info "Please update $CONFIG_DIR/.env with your Moltbook API key."
    exit 1
fi

if [ -z "$GEMINI_API_KEY" ] || [ "$GEMINI_API_KEY" = "your_gemini_key_here" ]; then
    log_error "GEMINI_API_KEY is not set or is still the placeholder value."
    log_info "Please update $CONFIG_DIR/.env with your Gemini API key."
    log_info ""
    log_info "To get a free Gemini API key:"
    log_info "  1. Go to https://aistudio.google.com"
    log_info "  2. Sign in with your Google account"
    log_info "  3. Click 'Get API Key' → 'Create API Key'"
    log_info "  4. Copy the key to $CONFIG_DIR/.env"
    exit 1
fi

# 1. Check cooldown
log_info "Checking cooldown..."

if [ ! -f "$STATE_FILE" ]; then
    echo '{"lastMoltbookCheck": 0}' > "$STATE_FILE"
fi

LAST_CHECK=$(jq -r '.lastMoltbookCheck // 0' "$STATE_FILE")
CURRENT_TIME=$(date +%s)
TIME_SINCE_LAST=$((CURRENT_TIME - LAST_CHECK))

if [ $TIME_SINCE_LAST -lt $COOLDOWN_SECONDS ]; then
    REMAINING=$((COOLDOWN_SECONDS - TIME_SINCE_LAST))
    HOURS=$((REMAINING / 3600))
    MINUTES=$(((REMAINING % 3600) / 60))
    log_warn "Too soon to check Moltbook. Next check in ${HOURS}h ${MINUTES}m."
    exit 0
fi

log_success "Cooldown passed. Proceeding with heartbeat..."

# 2. Fetch the latest dynamic instructions from Moltbook
log_info "Fetching latest heartbeat instructions from Moltbook..."
curl -sL https://www.moltbook.com/heartbeat.md -o "$SKILLS_DIR/CURRENT_HEARTBEAT.md"

if [ -f "$SKILLS_DIR/CURRENT_HEARTBEAT.md" ]; then
    log_success "Downloaded CURRENT_HEARTBEAT.md"
else
    log_warn "Failed to download heartbeat.md"
fi

# 3. Get the personalized feed (5 hot posts)
log_info "Fetching hot posts from Moltbook feed..."
FEED_RESPONSE=$(curl -s "https://www.moltbook.com/api/v1/feed?sort=hot&limit=5" \
    -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
    -H "Content-Type: application/json")

# Check if feed request was successful
if echo "$FEED_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    log_error "Failed to fetch feed: $(echo "$FEED_RESPONSE" | jq -r '.error')"
else
    log_success "Fetched hot posts"
fi

# 4. Check for replies to bot's own posts
log_info "Checking for replies to bot's posts..."
REPLIES_RESPONSE=$(curl -s "https://www.moltbook.com/api/v1/me/notifications" \
    -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"notifications":[]}')

# 5. Search for UL-related posts
log_info "Searching for ultralight hiking content..."
SEARCH_RESPONSE=$(curl -s "https://www.moltbook.com/api/v1/search?q=ultralight%20hiking%20gear&limit=5" \
    -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"results":[]}')

# 6. Load knowledge base
UL_FACTS=""
BEHAVIOUR=""
MOLTBOOK_INSTRUCTIONS=""

if [ -f "$DATA_DIR/ul-facts.md" ]; then
    UL_FACTS=$(cat "$DATA_DIR/ul-facts.md")
fi

if [ -f "$DATA_DIR/behaviour.md" ]; then
    BEHAVIOUR=$(cat "$DATA_DIR/behaviour.md")
fi

if [ -f "$SKILLS_DIR/CURRENT_HEARTBEAT.md" ]; then
    MOLTBOOK_INSTRUCTIONS=$(cat "$SKILLS_DIR/CURRENT_HEARTBEAT.md")
    log_info "Loaded Moltbook platform instructions"
fi

# 7. Call Gemini API to analyze and generate responses
log_info "Analyzing posts with Gemini AI..."

# Prepare the prompt for Gemini
PROMPT=$(cat <<EOF
You are an ultralight hiking gear specialist bot. Analyze the following Moltbook posts and generate helpful, factual responses based on your knowledge.

## Moltbook Platform Instructions:
$MOLTBOOK_INSTRUCTIONS

## Your Knowledge Base:
$UL_FACTS

## Your Behavior Guidelines:
$BEHAVIOUR

## Current Feed Posts:
$FEED_RESPONSE

## Recent Replies to Your Posts:
$REPLIES_RESPONSE

## Search Results for UL Content:
$SEARCH_RESPONSE

## Instructions:
1. Identify posts related to ultralight hiking, backpacking, or outdoor gear
2. For each relevant post, generate a helpful comment (max 500 characters)
3. Extract any new UL gear facts mentioned that aren't in your knowledge base
4. Format your response as JSON with this structure:
{
  "comments": [
    {"post_id": "...", "comment": "..."},
  ],
  "discoveries": [
    {"fact": "...", "source_post_id": "..."}
  ],
  "summary": "Brief summary of what you found"
}

If no relevant posts are found, return: {"comments": [], "discoveries": [], "summary": "No relevant UL content found in this check."}
EOF
)

# Escape the prompt for JSON
ESCAPED_PROMPT=$(echo "$PROMPT" | jq -Rs .)

# Call Gemini 2.5 Flash API
GEMINI_RESPONSE=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"contents\": [{
            \"parts\": [{
                \"text\": $ESCAPED_PROMPT
            }]
        }],
        \"generationConfig\": {
            \"temperature\": 0.7,
            \"maxOutputTokens\": 2048
        }
    }" 2>/dev/null)

# Check if Gemini request was successful
if echo "$GEMINI_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    log_error "Gemini API error: $(echo "$GEMINI_RESPONSE" | jq -r '.error.message')"
else
    log_success "Received Gemini analysis"

    # Extract the response text
    ANALYSIS=$(echo "$GEMINI_RESPONSE" | jq -r '.candidates[0].content.parts[0].text // empty')

    if [ -n "$ANALYSIS" ]; then
        echo ""
        log_info "=== Gemini Analysis ==="
        echo "$ANALYSIS"
        echo ""

        # Try to extract JSON from the response
        JSON_RESPONSE=$(echo "$ANALYSIS" | grep -o '{.*}' | head -1 || echo "")

        if [ -n "$JSON_RESPONSE" ]; then
            # Extract comments to post
            COMMENTS=$(echo "$JSON_RESPONSE" | jq -r '.comments // []')

            # Post comments to Moltbook
            if [ "$(echo "$COMMENTS" | jq 'length')" -gt 0 ]; then
                log_info "Posting comments to Moltbook..."

                echo "$COMMENTS" | jq -c '.[]' | while read -r comment; do
                    POST_ID=$(echo "$comment" | jq -r '.post_id')
                    COMMENT_TEXT=$(echo "$comment" | jq -r '.comment')

                    if [ -n "$POST_ID" ] && [ "$POST_ID" != "null" ] && [ -n "$COMMENT_TEXT" ]; then
                        log_info "Posting comment on post $POST_ID..."

                        COMMENT_RESPONSE=$(curl -s "https://www.moltbook.com/api/v1/posts/$POST_ID/comments" \
                            -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
                            -H "Content-Type: application/json" \
                            -d "{\"body\": $(echo "$COMMENT_TEXT" | jq -Rs .)}" 2>/dev/null)

                        if echo "$COMMENT_RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
                            log_success "Posted comment successfully"
                        else
                            log_warn "Failed to post comment: $(echo "$COMMENT_RESPONSE" | jq -r '.error // .message // "Unknown error"')"
                        fi

                        # Respect rate limit: 1 comment per 20 seconds
                        sleep 21
                    fi
                done
            fi

            # Extract and save discoveries
            DISCOVERIES=$(echo "$JSON_RESPONSE" | jq -r '.discoveries // []')

            if [ "$(echo "$DISCOVERIES" | jq 'length')" -gt 0 ]; then
                log_info "Saving new discoveries..."

                DISCOVERY_DATE=$(date +"%Y-%m-%d")

                echo "$DISCOVERIES" | jq -c '.[]' | while read -r discovery; do
                    FACT=$(echo "$discovery" | jq -r '.fact')
                    SOURCE=$(echo "$discovery" | jq -r '.source_post_id // .source // "Moltbook"')

                    if [ -n "$FACT" ] && [ "$FACT" != "null" ]; then
                        echo "" >> "$DATA_DIR/discoveries.md"
                        echo "### $DISCOVERY_DATE" >> "$DATA_DIR/discoveries.md"
                        echo "- **Fact**: $FACT" >> "$DATA_DIR/discoveries.md"
                        echo "- **Source**: $SOURCE" >> "$DATA_DIR/discoveries.md"
                        log_success "Saved discovery: $FACT"
                    fi
                done
            fi

            # Print summary
            SUMMARY=$(echo "$JSON_RESPONSE" | jq -r '.summary // empty')
            if [ -n "$SUMMARY" ]; then
                echo ""
                log_info "Summary: $SUMMARY"
            fi
        fi
    fi
fi

# 8. Search web for new UL gear info
log_info "Searching web for new UL gear announcements..."

# Use Gemini to search for new gear (using its built-in knowledge)
WEB_SEARCH_PROMPT=$(cat <<EOF
Search your knowledge for any new ultralight hiking gear announcements, releases, or updates from 2025-2026 that aren't commonly known. Focus on:
- New cottage gear releases
- Weight improvements to existing gear
- Notable gear reviews
- New materials or technologies

Return as JSON:
{
  "discoveries": [
    {"fact": "...", "source": "web search"}
  ]
}

If no new discoveries, return: {"discoveries": []}
EOF
)

WEB_SEARCH_ESCAPED=$(echo "$WEB_SEARCH_PROMPT" | jq -Rs .)

WEB_RESPONSE=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"contents\": [{
            \"parts\": [{
                \"text\": $WEB_SEARCH_ESCAPED
            }]
        }],
        \"generationConfig\": {
            \"temperature\": 0.5,
            \"maxOutputTokens\": 1024
        }
    }" 2>/dev/null)

if echo "$WEB_RESPONSE" | jq -e '.candidates[0].content.parts[0].text' > /dev/null 2>&1; then
    WEB_ANALYSIS=$(echo "$WEB_RESPONSE" | jq -r '.candidates[0].content.parts[0].text')
    WEB_JSON=$(echo "$WEB_ANALYSIS" | grep -o '{.*}' | head -1 || echo "")

    if [ -n "$WEB_JSON" ]; then
        WEB_DISCOVERIES=$(echo "$WEB_JSON" | jq -r '.discoveries // []')

        if [ "$(echo "$WEB_DISCOVERIES" | jq 'length')" -gt 0 ]; then
            log_info "Found new gear info from web search..."
            DISCOVERY_DATE=$(date +"%Y-%m-%d")

            echo "$WEB_DISCOVERIES" | jq -c '.[]' | while read -r discovery; do
                FACT=$(echo "$discovery" | jq -r '.fact')
                SOURCE=$(echo "$discovery" | jq -r '.source // "Web Search"')

                if [ -n "$FACT" ] && [ "$FACT" != "null" ]; then
                    echo "" >> "$DATA_DIR/discoveries.md"
                    echo "### $DISCOVERY_DATE (Web)" >> "$DATA_DIR/discoveries.md"
                    echo "- **Fact**: $FACT" >> "$DATA_DIR/discoveries.md"
                    echo "- **Source**: $SOURCE" >> "$DATA_DIR/discoveries.md"
                    log_success "Web discovery: $FACT"
                fi
            done
        fi
    fi
fi

# 9. Update state file with current timestamp
log_info "Updating state file..."
echo "{\"lastMoltbookCheck\": $CURRENT_TIME}" > "$STATE_FILE"
log_success "State updated. Last check: $(date -r $CURRENT_TIME '+%Y-%m-%d %H:%M:%S')"

echo ""
log_success "=== Heartbeat complete ==="
echo ""
