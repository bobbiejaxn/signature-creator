#!/bin/bash
# ════════════════════════════════════════════════════════════════
# onboard-project.sh — Add a new project to the event-driven system
# ════════════════════════════════════════════════════════════════
# Usage: ./onboard-project.sh <project-slug> <github-repo> <prod-url> <deploy-method> <telegram-channel-id>
#
# Example:
#   ./onboard-project.sh my-app bobbiejaxn/my-app https://my-app.debored.ai netcup -5123456789
#   ./onboard-project.sh my-saas bobbiejaxn/my-saas https://my-saas.com vercel -5123456789
#
# What it does:
#   1. Registers GitHub webhook on the repo
#   2. Adds to gateway project_map
#   3. Adds to deploy_on_push handler
#   4. Adds to notify_telegram channel map
#   5. Adds to trigger_ceo_agent job map
#   6. Creates CEO goal cron job
#   7. Clones repo to /root/projects/active/
#   8. Creates .pi/config.sh
# ════════════════════════════════════════════════════════════════

set -euo pipefail

SLUG="${1:?Usage: onboard-project.sh <slug> <repo> <prod-url> <deploy-method> <channel-id>}"
REPO="${2:?Missing github repo (e.g. bobbiejaxn/my-app)}"
PROD_URL="${3:?Missing production URL}"
DEPLOY_METHOD="${4:?Missing deploy method (netcup|vercel)}"
CHANNEL_ID="${5:?Missing telegram channel ID}"

REPO_NAME=$(echo "$REPO" | cut -d/ -f2)
GATEWAY_HOST="netcup"
HOSTINGER_HOST="root@srv1398187.hstgr.cloud"
SSH_KEY="/root/.ssh/id_ed25519"

echo "════════════════════════════════════════"
echo "  Onboarding: $SLUG"
echo "  Repo: $REPO"
echo "  URL: $PROD_URL"
echo "  Deploy: $DEPLOY_METHOD"
echo "  Channel: $CHANNEL_ID"
echo "════════════════════════════════════════"
echo ""

# 1. Register GitHub webhook
echo "1. Registering GitHub webhook..."
gh api -X POST "repos/$REPO/hooks" --input - << EOF
{"name":"web","active":true,"events":["push","pull_request","issues"],
 "config":{"url":"https://gateway.debored.ai/webhooks/github","content_type":"json"}}
EOF
echo "   ✅ Webhook registered"

# 2. Add to gateway project_map
echo "2. Adding to gateway project_map..."
ssh $GATEWAY_HOST "
    grep -q '$REPO_NAME' /opt/event-gateway/config.yaml 2>/dev/null || \
    sed -i '/project_map:/a\\  $REPO_NAME: $SLUG' /opt/event-gateway/config.yaml
"
echo "   ✅ Project map updated"

# 3. Add to deploy handler
echo "3. Adding to deploy handler..."
if [ "$DEPLOY_METHOD" = "vercel" ]; then
    DEPLOY_CMD="cd /root/projects/active/$SLUG && vercel --prod --token \\\$VERCEL_TOKEN --yes"
    DEPLOY_SSH="true"
else
    DEPLOY_CMD="cd /opt/$SLUG && git pull && docker compose up -d --build"
    DEPLOY_SSH="false"
fi

ssh $GATEWAY_HOST "python3 -c \"
with open('/opt/event-gateway/handlers/deploy_on_push.py') as f:
    c = f.read()
if '$REPO_NAME' not in c:
    c = c.replace(
        '}\\n\\nHOSTINGER',
        '    \\\"$REPO_NAME\\\": {\\n        \\\"method\\\": \\\"$DEPLOY_METHOD\\\",\\n        \\\"command\\\": \\\"$DEPLOY_CMD\\\",\\n        \\\"verify\\\": \\\"curl -so /dev/null -w \\'%{http_code}\\' $PROD_URL\\\",\\n        \\\"ssh\\\": $DEPLOY_SSH,\\n    },\\n}\\n\\nHOSTINGER'
    )
    with open('/opt/event-gateway/handlers/deploy_on_push.py', 'w') as f:
        f.write(c)
    print('Added')
else:
    print('Already exists')
\""
echo "   ✅ Deploy handler updated"

# 4-5. Add to notify + trigger handlers
echo "4. Adding to notification + trigger handlers..."
ssh $GATEWAY_HOST "python3 -c \"
import json

# Notify handler
with open('/opt/event-gateway/handlers/notify_telegram.py') as f:
    c = f.read()
if '$SLUG' not in c:
    c = c.replace('\\\"infrastructure\\\"', '\\\"$SLUG\\\": \\\"$CHANNEL_ID\\\",\\n    \\\"infrastructure\\\"')
    with open('/opt/event-gateway/handlers/notify_telegram.py', 'w') as f:
        f.write(c)

# Trigger handler
with open('/opt/event-gateway/handlers/trigger_ceo_agent.py') as f:
    c = f.read()
if '$SLUG' not in c:
    c = c.replace('}\\n\\n# Only trigger', '    \\\"$SLUG\\\": \\\"PLACEHOLDER_JOB_ID\\\",\\n}\\n\\n# Only trigger')
    with open('/opt/event-gateway/handlers/trigger_ceo_agent.py', 'w') as f:
        f.write(c)
\""
echo "   ✅ Handlers updated"

# 6. Create CEO goal cron job
echo "5. Creating CEO goal cron job..."
JOB_ID=$(echo -n "${SLUG}-ceo-goal" | md5sum | cut -c1-12)
ssh -o ConnectTimeout=5 -i $SSH_KEY $HOSTINGER "docker exec hermes-solo python3 -c \"
import json, hashlib
with open('/hermes-home/cron/jobs.json') as f:
    d = json.load(f)

if any(j.get('name') == '$SLUG-ceo-goal' for j in d['jobs']):
    print('Already exists')
else:
    d['jobs'].append({
        'id': '$JOB_ID',
        'name': '$SLUG-ceo-goal',
        'prompt': '''You ARE the CEO agent for $SLUG. Work directly on the project until the goal is achieved or you need to escalate.

## Goal
Assess the current state of $SLUG, identify priorities, and ship improvements. Focus on what moves the needle most.

## Verify-Fix Loop
Before doing anything new, check: did my last fix work? Read /hermes-home/cron/output/approaches-$SLUG.log for what was already tried.

## Quality Gates (before every push)
Run typecheck, lint, build. Do NOT push broken code.

## Deploy Instructions
Deploy: $DEPLOY_CMD
Verify: curl -so /dev/null -w \\'%{http_code}\\' $PROD_URL

## Visual Verification (after every deploy)
Screenshot the live site and verify visually.

[OUTPUT RULE: End with paste-to-fix blocks for any issues.]''',
        'schedule': {'kind': 'cron', 'expr': '0 10,18 * * *', 'display': '0 10,18 * * *'},
        'schedule_display': '0 10,18 * * *',
        'model': 'glm-5.1', 'provider': 'zai', 'base_url': None,
        'deliver': 'telegram:$CHANNEL_ID',
        'repeat': 'forever', 'enabled': True, 'state': 'scheduled',
        'skills': [], 'skill': None,
        'created_at': None, 'origin': None,
        'last_run_at': None, 'last_status': None, 'last_error': None,
        'paused_at': None, 'paused_reason': None, 'next_run_at': None,
    })
    with open('/hermes-home/cron/jobs.json', 'w') as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print('Created job $JOB_ID')
\""

# Update trigger handler with real job ID
ssh $GATEWAY_HOST "sed -i 's/PLACEHOLDER_JOB_ID/$JOB_ID/' /opt/event-gateway/handlers/trigger_ceo_agent.py"
echo "   ✅ CEO goal cron created (id=$JOB_ID)"

# 7. Clone repo
echo "6. Cloning repo..."
ssh -o ConnectTimeout=5 -i $SSH_KEY $HOSTINGER "
    [ -d /root/projects/active/$SLUG ] || \
    git clone https://github.com/$REPO.git /root/projects/active/$SLUG 2>&1 | tail -1
"
echo "   ✅ Repo cloned"

# 8. Create .pi/config.sh
echo "7. Creating .pi/config.sh..."
ssh -o ConnectTimeout=5 -i $SSH_KEY $HOSTINGER "
    mkdir -p /root/projects/active/$SLUG/.pi
    cat > /root/projects/active/$SLUG/.pi/config.sh << PIEOF
#!/bin/bash
source ~/.pi/config.sh
PROJECT_NAME=\"$SLUG\"
REPO=\"$REPO\"
PROD_URL=\"$PROD_URL\"
PIEOF
"
echo "   ✅ Config created"

# Reload gateway
echo "8. Reloading gateway..."
ssh $GATEWAY_HOST "curl -s -X POST http://localhost:3200/reload | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"status\"])'"

echo ""
echo "════════════════════════════════════════"
echo "  ✅ $SLUG fully onboarded"
echo ""
echo "  Webhook: ✅"
echo "  Gateway: ✅ (deploy + notify + trigger)"
echo "  CEO goal: ✅ (twice daily + event-driven)"
echo "  Project: /root/projects/active/$SLUG"
echo "  Channel: $CHANNEL_ID"
echo "════════════════════════════════════════"
