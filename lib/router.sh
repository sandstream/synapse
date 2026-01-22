#!/bin/bash
# =============================================================================
# lib/router.sh - Task Detection & Model Routing
#
# Automatically routes tasks to the most suitable model based on:
#   1. Task type detection (architect, codegen, fix, review, test)
#   2. Configuration from .infernorc
#   3. Environment overrides
#
# Configuration (via .infernorc):
#   {
#     "taskModels": {
#       "architect": "claude-opus",
#       "codegen": "deepseek/deepseek-chat",
#       "fix": "gemini-flash",
#       "review": "claude-sonnet",
#       "test": "deepseek/deepseek-coder"
#     }
#   }
#
# Environment:
#   INFERNO_TASK_MODEL_ARCHITECT - Override architect model
#   INFERNO_TASK_MODEL_CODEGEN   - Override codegen model
#   INFERNO_TASK_MODEL_FIX       - Override fix model
#   INFERNO_TASK_MODEL_REVIEW    - Override review model
#   INFERNO_TASK_MODEL_TEST      - Override test model
#   INFERNO_AUTO_ROUTE           - Enable/disable auto-routing (default: true)
# =============================================================================

# Default task models (used when no config found)
# Using simple variables instead of associative arrays for compatibility
DEFAULT_MODEL_ARCHITECT="claude-sonnet-4-20250514"
DEFAULT_MODEL_CODEGEN="claude-sonnet-4-20250514"
DEFAULT_MODEL_FIX="claude-sonnet-4-20250514"
DEFAULT_MODEL_REVIEW="claude-sonnet-4-20250514"
DEFAULT_MODEL_TEST="claude-sonnet-4-20250514"

# Loaded task models (from config)
TASK_MODEL_ARCHITECT=""
TASK_MODEL_CODEGEN=""
TASK_MODEL_FIX=""
TASK_MODEL_REVIEW=""
TASK_MODEL_TEST=""
TASK_MODELS_LOADED=false

# Auto-routing enabled by default
INFERNO_AUTO_ROUTE="${INFERNO_AUTO_ROUTE:-true}"

# =============================================================================
# Configuration Loading
# =============================================================================

# Load task router configuration from .infernorc
# Usage: load_task_router_config [config_file]
load_task_router_config() {
    local config_file="${1:-.infernorc}"

    # Initialize with defaults
    TASK_MODEL_ARCHITECT="$DEFAULT_MODEL_ARCHITECT"
    TASK_MODEL_CODEGEN="$DEFAULT_MODEL_CODEGEN"
    TASK_MODEL_FIX="$DEFAULT_MODEL_FIX"
    TASK_MODEL_REVIEW="$DEFAULT_MODEL_REVIEW"
    TASK_MODEL_TEST="$DEFAULT_MODEL_TEST"

    # Load from config file if it exists
    if [ -f "$config_file" ]; then
        local task_models_json
        task_models_json=$(jq -c '.taskModels // {}' "$config_file" 2>/dev/null)

        if [ -n "$task_models_json" ] && [ "$task_models_json" != "{}" ]; then
            local model
            model=$(echo "$task_models_json" | jq -r '.architect // empty')
            [ -n "$model" ] && [ "$model" != "null" ] && TASK_MODEL_ARCHITECT="$model"

            model=$(echo "$task_models_json" | jq -r '.codegen // empty')
            [ -n "$model" ] && [ "$model" != "null" ] && TASK_MODEL_CODEGEN="$model"

            model=$(echo "$task_models_json" | jq -r '.fix // empty')
            [ -n "$model" ] && [ "$model" != "null" ] && TASK_MODEL_FIX="$model"

            model=$(echo "$task_models_json" | jq -r '.review // empty')
            [ -n "$model" ] && [ "$model" != "null" ] && TASK_MODEL_REVIEW="$model"

            model=$(echo "$task_models_json" | jq -r '.test // empty')
            [ -n "$model" ] && [ "$model" != "null" ] && TASK_MODEL_TEST="$model"
        fi
    fi

    # Override from environment variables
    [ -n "${INFERNO_TASK_MODEL_ARCHITECT:-}" ] && TASK_MODEL_ARCHITECT="$INFERNO_TASK_MODEL_ARCHITECT"
    [ -n "${INFERNO_TASK_MODEL_CODEGEN:-}" ] && TASK_MODEL_CODEGEN="$INFERNO_TASK_MODEL_CODEGEN"
    [ -n "${INFERNO_TASK_MODEL_FIX:-}" ] && TASK_MODEL_FIX="$INFERNO_TASK_MODEL_FIX"
    [ -n "${INFERNO_TASK_MODEL_REVIEW:-}" ] && TASK_MODEL_REVIEW="$INFERNO_TASK_MODEL_REVIEW"
    [ -n "${INFERNO_TASK_MODEL_TEST:-}" ] && TASK_MODEL_TEST="$INFERNO_TASK_MODEL_TEST"

    TASK_MODELS_LOADED=true
}

# =============================================================================
# Task Type Detection
# =============================================================================

# Detect task type from prompt
# Usage: task_type=$(detect_task_type "Fix the bug in login.ts")
# Returns: architect, codegen, fix, review, or test
detect_task_type() {
    local prompt="$1"
    local prompt_lower
    prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    # Architecture/Planning tasks
    if echo "$prompt_lower" | grep -qiE '\b(plan|design|architect|structure|organize|refactor large|rewrite|migration strategy|system design|api design)\b'; then
        echo "architect"
        return
    fi

    # Fix/Bug tasks
    if echo "$prompt_lower" | grep -qiE '\b(fix|bug|error|issue|broken|crash|fail|not working|doesn.t work|won.t|problem|debug)\b'; then
        echo "fix"
        return
    fi

    # Review tasks
    if echo "$prompt_lower" | grep -qiE '\b(review|check|audit|analyze|inspect|examine|verify|validate|security|vulnerability|improve|optimize)\b'; then
        echo "review"
        return
    fi

    # Test tasks
    if echo "$prompt_lower" | grep -qiE '\b(test|spec|unit test|integration test|e2e|coverage|mock|stub|assertion|expect|describe|it\()\b'; then
        echo "test"
        return
    fi

    # Default to codegen for everything else
    echo "codegen"
}

# Get detailed task classification with confidence
# Usage: classification=$(get_task_classification "prompt")
# Returns: JSON with type, confidence, and keywords
get_task_classification() {
    local prompt="$1"
    local prompt_lower
    prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    local task_type confidence keywords

    # Count keyword matches for each category
    local architect_score=0 fix_score=0 review_score=0 test_score=0 codegen_score=0

    # Architect keywords
    for kw in "plan" "design" "architect" "structure" "organize" "refactor" "migration" "system" "api design"; do
        if echo "$prompt_lower" | grep -qiw "$kw"; then
            ((architect_score++))
        fi
    done

    # Fix keywords
    for kw in "fix" "bug" "error" "issue" "broken" "crash" "fail" "problem" "debug"; do
        if echo "$prompt_lower" | grep -qiw "$kw"; then
            ((fix_score++))
        fi
    done

    # Review keywords
    for kw in "review" "check" "audit" "analyze" "inspect" "verify" "validate" "security" "improve"; do
        if echo "$prompt_lower" | grep -qiw "$kw"; then
            ((review_score++))
        fi
    done

    # Test keywords
    for kw in "test" "spec" "unit" "integration" "e2e" "coverage" "mock" "assertion"; do
        if echo "$prompt_lower" | grep -qiw "$kw"; then
            ((test_score++))
        fi
    done

    # Codegen keywords (creation indicators)
    for kw in "create" "add" "implement" "build" "make" "generate" "write" "new"; do
        if echo "$prompt_lower" | grep -qiw "$kw"; then
            ((codegen_score++))
        fi
    done

    # Find highest score
    local max_score=$codegen_score
    task_type="codegen"

    if [ $architect_score -gt $max_score ]; then
        max_score=$architect_score
        task_type="architect"
    fi
    if [ $fix_score -gt $max_score ]; then
        max_score=$fix_score
        task_type="fix"
    fi
    if [ $review_score -gt $max_score ]; then
        max_score=$review_score
        task_type="review"
    fi
    if [ $test_score -gt $max_score ]; then
        max_score=$test_score
        task_type="test"
    fi

    # Calculate confidence (0-1)
    local total_score=$((architect_score + fix_score + review_score + test_score + codegen_score))
    if [ $total_score -gt 0 ]; then
        # Higher ratio = higher confidence
        confidence=$(echo "scale=2; $max_score / ($total_score + 1)" | bc)
    else
        confidence="0.50"
    fi

    jq -n \
        --arg type "$task_type" \
        --arg confidence "$confidence" \
        --argjson scores "{\"architect\": $architect_score, \"fix\": $fix_score, \"review\": $review_score, \"test\": $test_score, \"codegen\": $codegen_score}" \
        '{type: $type, confidence: $confidence, scores: $scores}'
}

# =============================================================================
# Model Selection
# =============================================================================

# Get model for a specific task type
# Usage: model=$(get_model_for_task "architect")
get_model_for_task() {
    local task_type="$1"

    # Make sure config is loaded
    if [ "$TASK_MODELS_LOADED" != "true" ]; then
        load_task_router_config
    fi

    local model=""
    case "$task_type" in
        architect) model="$TASK_MODEL_ARCHITECT" ;;
        codegen)   model="$TASK_MODEL_CODEGEN" ;;
        fix)       model="$TASK_MODEL_FIX" ;;
        review)    model="$TASK_MODEL_REVIEW" ;;
        test)      model="$TASK_MODEL_TEST" ;;
    esac

    if [ -z "$model" ]; then
        # Fallback to default model
        echo "${LLM_MODEL:-claude-sonnet-4-20250514}"
    else
        echo "$model"
    fi
}

# Get provider for a model (infer from model name)
# Usage: provider=$(get_provider_for_model "deepseek/deepseek-chat")
get_provider_for_model() {
    local model="$1"

    # Check for provider prefix (openrouter format)
    if [[ "$model" == */* ]]; then
        # Models like "anthropic/claude-3", "deepseek/deepseek-chat"
        echo "openrouter"
        return
    fi

    # Check for known model patterns
    case "$model" in
        claude-*|anthropic-*)
            echo "anthropic"
            ;;
        gpt-*|o1-*)
            echo "openai"
            ;;
        llama*|mistral*|codellama*|phi-*)
            echo "ollama"
            ;;
        deepseek-*|gemini-*|meta-*)
            echo "openrouter"
            ;;
        *)
            # Default to anthropic
            echo "anthropic"
            ;;
    esac
}

# Get full routing decision for a prompt
# Usage: route=$(get_route_for_prompt "Fix the TypeScript error")
# Returns: JSON with model, provider, task_type
get_route_for_prompt() {
    local prompt="$1"

    # Load config if not already loaded
    if [ "$TASK_MODELS_LOADED" != "true" ]; then
        load_task_router_config
    fi

    local task_type model provider

    if [ "$INFERNO_AUTO_ROUTE" = "true" ]; then
        task_type=$(detect_task_type "$prompt")
        model=$(get_model_for_task "$task_type")
        provider=$(get_provider_for_model "$model")
    else
        # Use default/environment model
        task_type="manual"
        model="${LLM_MODEL:-claude-sonnet-4-20250514}"
        provider="${LLM_PROVIDER:-anthropic}"
    fi

    jq -n \
        --arg task_type "$task_type" \
        --arg model "$model" \
        --arg provider "$provider" \
        '{task_type: $task_type, model: $model, provider: $provider}'
}

# Apply routing to environment variables
# Usage: apply_route "$(get_route_for_prompt "$prompt")"
apply_route() {
    local route_json="$1"

    export LLM_MODEL=$(echo "$route_json" | jq -r '.model')
    export LLM_PROVIDER=$(echo "$route_json" | jq -r '.provider')
}

# =============================================================================
# Utility Functions
# =============================================================================

# Print current routing configuration
print_routing_config() {
    echo "Task Router Configuration:"
    echo "========================="
    echo "Auto-routing: $INFERNO_AUTO_ROUTE"
    echo ""
    echo "Task → Model mapping:"

    # Load if needed
    if [ "$TASK_MODELS_LOADED" != "true" ]; then
        load_task_router_config
    fi

    local model provider
    for task_type in architect codegen fix review test; do
        model=$(get_model_for_task "$task_type")
        provider=$(get_provider_for_model "$model")
        printf "  %-10s → %s (%s)\n" "$task_type" "$model" "$provider"
    done
}

# Test routing with a prompt
# Usage: test_routing "Fix the bug in App.tsx"
test_routing() {
    local prompt="$1"

    echo "Testing routing for prompt:"
    echo "  \"$prompt\""
    echo ""

    local classification
    classification=$(get_task_classification "$prompt")

    echo "Classification:"
    echo "$classification" | jq .
    echo ""

    local route
    route=$(get_route_for_prompt "$prompt")

    echo "Route:"
    echo "$route" | jq .
}

# =============================================================================
# Task Complexity Assessment
# =============================================================================

# Assess task complexity to help with model selection
# Usage: complexity=$(assess_task_complexity "prompt")
# Returns: simple, medium, or complex
assess_task_complexity() {
    local prompt="$1"
    local prompt_lower
    prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

    local complexity_score=0

    # Indicators of complexity
    [[ "$prompt_lower" == *"multiple"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"several"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"all"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"entire"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"comprehensive"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"complete"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"full"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"refactor"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"migrate"* ]] && ((complexity_score++))
    [[ "$prompt_lower" == *"redesign"* ]] && ((complexity_score++))

    # Indicators of simplicity
    [[ "$prompt_lower" == *"simple"* ]] && ((complexity_score--))
    [[ "$prompt_lower" == *"small"* ]] && ((complexity_score--))
    [[ "$prompt_lower" == *"quick"* ]] && ((complexity_score--))
    [[ "$prompt_lower" == *"just"* ]] && ((complexity_score--))
    [[ "$prompt_lower" == *"only"* ]] && ((complexity_score--))

    # Length-based complexity
    local word_count
    word_count=$(echo "$prompt" | wc -w)
    [ "$word_count" -gt 50 ] && ((complexity_score++))
    [ "$word_count" -gt 100 ] && ((complexity_score++))

    # Return complexity level
    if [ $complexity_score -le 0 ]; then
        echo "simple"
    elif [ $complexity_score -le 2 ]; then
        echo "medium"
    else
        echo "complex"
    fi
}

# Get recommended model tier based on complexity
# Usage: tier=$(get_model_tier_for_complexity "complex")
get_model_tier_for_complexity() {
    local complexity="$1"

    case "$complexity" in
        simple)
            echo "fast"  # Use faster/cheaper models
            ;;
        medium)
            echo "balanced"  # Use balanced models
            ;;
        complex)
            echo "powerful"  # Use most capable models
            ;;
        *)
            echo "balanced"
            ;;
    esac
}
