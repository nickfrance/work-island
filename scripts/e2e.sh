#!/usr/bin/env bash
# Teste ponta a ponta: roda o Claude Code de verdade (modelo haiku, custa alguns tokens do plano)
# com o plugin da Work Island carregado só nesta chamada (--plugin-dir), sem instalar nada.
#
#   scripts/e2e.sh [concluido]  sessão aparece como "done" em state.json (app aberto normalmente)
#   scripts/e2e.sh permissao    pedido de permissão respondido pela ilha: permitir e negar
#                               (o app precisa estar aberto com ILHA_DEBUG=1, veja o README)
#   scripts/e2e.sh pergunta     pergunta (AskUserQuestion) respondida pela ilha, e devolvida ao app
#                               sem virar um segundo pedido (app em ILHA_DEBUG=1)
#   scripts/e2e.sh tudo         todos (exige o app em ILHA_DEBUG=1)
#
# Sai com 0 (passou), 1 (falhou) ou 2 (app fechado, ou sem ILHA_DEBUG=1 quando o caso pede).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/Work Island"
SOCK="$SUPPORT/ilha.sock"
STATE="$SUPPORT/state.json"
REQUESTS="$SUPPORT/requests.json"
CASE="${1:-concluido}"

case "$CASE" in
  concluido|permissao|pergunta|tudo) ;;
  *) echo "uso: scripts/e2e.sh [concluido|permissao|pergunta|tudo]" >&2; exit 2 ;;
esac

# O arquivo do socket pode sobrar depois que o app fecha: só vale se alguém aceita a conexão.
if ! python3 - "$SOCK" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])
PY
then
  echo "A Work Island não está rodando (ninguém escutando em $SOCK). Abra o app com: open \"$ROOT/build/Work Island.app\"" >&2
  exit 2
fi

if [[ "$CASE" != "concluido" ]]; then
  # Os casos de permissão e pergunta respondem pelo comando de teste do app, que só existe com ILHA_DEBUG=1.
  APP_PID="$(pgrep -x WorkIsland | head -1 || true)"
  if [[ -z "$APP_PID" ]] || ! ps eww -p "$APP_PID" 2>/dev/null | tr ' ' '\n' | grep -qx 'ILHA_DEBUG=1'; then
    echo "O caso \"$CASE\" precisa do app aberto com ILHA_DEBUG=1: feche a Work Island e rode" >&2
    echo "  ILHA_DEBUG=1 \"$ROOT/build/Work Island.app/Contents/MacOS/WorkIsland\" &" >&2
    exit 2
  fi
fi

if [[ ! -x "$ROOT/plugin/bin/ilha-hook" ]]; then
  "$ROOT/scripts/build-plugin.sh"
fi

TMP="$(mktemp -d)"
REAL_TMP="$(cd "$TMP" && pwd -P)"
CLAUDE_PID=""    # o claude -p em andamento (para a limpeza)
ACTIVE_REAL=""   # a pasta da sessão de permissão ou pergunta em andamento (para devolver pedidos que sobrarem)

# Ctrl-C, SIGTERM ou erro no meio: não deixa claude -p órfão, nem cartão velho na ilha do usuário
# (os pedidos pendentes da sessão voltam para o app de origem com passThrough).
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null || true
  fi
  if [[ -n "$ACTIVE_REAL" ]] && declare -F pending_requests >/dev/null; then
    local id
    for id in $(pending_requests "$ACTIVE_REAL" 2>/dev/null || true); do
      printf '{"debugAnswer":"%s","decision":"passThrough"}\n' "$id" | nc -w 2 -U "$SOCK" 2>/dev/null || true
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- caso: concluído

# O Claude Code em modo -p sai logo depois do Stop e o SessionEnd remove a sessão da ilha.
# Para dar tempo de observar o "concluído", esta chamada (e só ela, via --settings) acrescenta um
# hook de Stop que dorme alguns segundos; o ilha-hook do Stop roda em paralelo, sem esperar.
HOLD='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sleep 4"}]}]}}'

found() {
  python3 - "$STATE" "$REAL_TMP" <<'PY'
import json, os, sys
state_path, target = sys.argv[1], sys.argv[2]
try:
    with open(state_path) as f:
        sessions = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
for s in sessions:
    if os.path.realpath(s.get("cwd", "")) == target and s.get("state") == "done":
        sys.exit(0)
sys.exit(1)
PY
}

case_concluido() {
  local dir="$TMP/concluido"
  mkdir -p "$dir"
  REAL_TMP="$(cd "$dir" && pwd -P)"
  (cd "$dir" && exec claude -p "Responda só: ok" --model haiku --plugin-dir "$ROOT/plugin" --settings "$HOLD" >/dev/null) &
  CLAUDE_PID=$!
  local claude_pid=$CLAUDE_PID

  # O app grava state.json de forma assíncrona: confere enquanto o claude roda (até ~60 s) e mais um pouco depois.
  for _ in $(seq 1 300); do
    if found; then
      echo "PASSOU (concluído): sessão de $REAL_TMP apareceu como concluída na ilha"
      wait "$claude_pid" || true
      CLAUDE_PID=""
      return 0
    fi
    kill -0 "$claude_pid" 2>/dev/null || break
    sleep 0.2
  done

  wait "$claude_pid" || true
  CLAUDE_PID=""
  echo "FALHOU (concluído): nenhuma sessão concluída com cwd $REAL_TMP em $STATE"
  return 1
}

# ---------------------------------------------------------------- caso: permissão

# Imprime, um por linha, os ids dos pedidos pendentes da sessão cujo cwd é $1; com $2 (permission|questions),
# só os desse tipo; com $3 = "title", cada linha é "id<TAB>título" (numa pergunta, o texto da primeira).
pending_requests() {
  python3 - "$STATE" "$REQUESTS" "$1" "${2:-}" "${3:-}" <<'PY'
import json, os, sys
state_path, requests_path, target, kind, fmt = sys.argv[1:6]
try:
    with open(state_path) as f:
        sessions = json.load(f)
    with open(requests_path) as f:
        requests = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
ids = {s["id"] for s in sessions if os.path.realpath(s.get("cwd", "")) == target}
for r in requests:
    if r.get("sessionID") in ids and (not kind or r.get("kind") == kind):
        print(r["id"] + ("\t" + r.get("title", "").replace("\t", " ").replace("\n", " ") if fmt == "title" else ""))
PY
}

pending_permissions() { pending_requests "$1" permission; }

# Responde um pedido pelo comando de teste do app (decision: allow|deny|passThrough).
answer() {
  local id="$1" decision="$2"
  if [[ "$decision" == "deny" ]]; then
    printf '{"debugAnswer":"%s","decision":"deny","message":"Não é pra criar esse arquivo. Não tente de novo nem de outro jeito."}\n' "$id" | nc -w 2 -U "$SOCK"
  else
    printf '{"debugAnswer":"%s","decision":"%s"}\n' "$id" "$decision" | nc -w 2 -U "$SOCK"
  fi
}

# case_permissao allow|deny
case_permissao() {
  local decision="$1"
  local dir="$TMP/permissao-$decision"
  mkdir -p "$dir"
  local real; real="$(cd "$dir" && pwd -P)"
  local out="$TMP/saida-$decision.json"
  local prompt="Use a ferramenta Bash para rodar exatamente este comando: echo oi > teste.txt. Depois responda só: feito"

  # Sem --allowedTools e em modo default, o Bash cai em PermissionRequest e o hook da ilha segura o pedido.
  # --tools Bash e --max-turns 4 limitam o que o modelo pode tentar depois de uma negativa.
  ACTIVE_REAL="$real"
  (cd "$dir" && exec claude -p "$prompt" --model haiku --permission-mode default --output-format json \
    --tools Bash --max-turns 4 --plugin-dir "$ROOT/plugin" >"$out" 2>"$TMP/erro-$decision.txt") &
  CLAUDE_PID=$!

  # Responde TODO pedido pendente da sessão do mesmo jeito (o modelo pode tentar de novo depois de
  # uma negativa). O hook segura até 305 s; o teste desiste antes (120 s, medidos com SECONDS).
  local answered=0 seen=" " id deadline=$((SECONDS + 120))
  while kill -0 "$CLAUDE_PID" 2>/dev/null && (( SECONDS < deadline )); do
    for id in $(pending_permissions "$real"); do
      [[ "$seen" == *" $id "* ]] && continue
      seen+="$id "
      answer "$id" "$decision" && answered=$((answered + 1))
    done
    sleep 0.2
  done
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null || true
    wait "$CLAUDE_PID" 2>/dev/null || true
    CLAUDE_PID=""
    echo "FALHOU (permissão/$decision): o claude não terminou em 120 s (pedidos respondidos: $answered)"
    head -c 600 "$out" 2>/dev/null || true
    return 1
  fi
  wait "$CLAUDE_PID" || true
  CLAUDE_PID=""
  ACTIVE_REAL=""

  if (( answered == 0 )); then
    echo "FALHOU (permissão/$decision): nenhum pedido de permissão apareceu em $REQUESTS para $real"
    head -c 600 "$out" 2>/dev/null || true; head -c 600 "$TMP/erro-$decision.txt" 2>/dev/null || true
    return 1
  fi

  local ok=0
  if [[ "$decision" == "allow" ]]; then
    if [[ -f "$dir/teste.txt" && "$(tr -d '\n' <"$dir/teste.txt")" == "oi" ]]; then ok=1; fi
  else
    if [[ ! -e "$dir/teste.txt" ]]; then ok=1; fi
  fi
  if (( ok )); then
    echo "PASSOU (permissão/$decision): $answered pedido(s) respondido(s); teste.txt $([[ $decision == allow ]] && echo 'existe com "oi"' || echo 'não foi criado')"
    if [[ "$decision" == "deny" ]]; then
      python3 - "$out" <<'PY' || true
import json, sys
try:
    print("  resposta do modelo:", json.load(open(sys.argv[1])).get("result", "")[:200].replace("\n", " "))
except Exception:
    pass
PY
    fi
    return 0
  fi
  echo "FALHOU (permissão/$decision): estado inesperado de $dir/teste.txt"
  head -c 800 "$out" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------- caso: pergunta

# Responde a pergunta $1 (id) com o rótulo $3 para o texto $2, pelo comando de teste do app.
answer_question() {
  python3 - "$1" "$2" "$3" <<'PY' | nc -w 2 -U "$SOCK"
import json, sys
id_, question, label = sys.argv[1:4]
print(json.dumps({"debugAnswer": id_, "decision": "answer", "answers": {question: label}}, ensure_ascii=False))
PY
}

# Em `claude -p` comum a ferramenta AskUserQuestion não existe (conferido em 25/10: a lista de
# ferramentas vem sem ela mesmo com --tools AskUserQuestion). Ela aparece no modo do Agent SDK:
# entrada e saída stream-json com --permission-prompt-tool stdio. Este driver manda o prompt, nega
# qualquer pedido de permissão que o Claude Code fizer pelo stdio (é o "app de origem" do -p),
# fecha a entrada quando chega o resultado e grava a última mensagem `result` em $1.
# SIGTERM/SIGINT encerram também o claude.
write_question_driver() {
  cat >"$TMP/pergunta.py" <<'PY'
import json, signal, subprocess, sys
out_path, prompt, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

def stop(*_):
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
    sys.exit(143)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def send(obj):
    try:
        proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        proc.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass

send({"type": "user", "message": {"role": "user", "content": prompt}})
result = None
for line in proc.stdout:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("type") == "control_request" and msg.get("request", {}).get("subtype") == "can_use_tool":
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id"),
              "response": {"behavior": "deny", "message": "Negado pelo teste."}}})
    elif msg.get("type") == "result":
        result = msg
        break
try:
    proc.stdin.close()
except (BrokenPipeError, ValueError):
    pass
try:
    proc.wait(30)
except subprocess.TimeoutExpired:
    proc.kill()
with open(out_path, "w") as f:
    json.dump(result or {}, f, ensure_ascii=False)
PY
}

# case_pergunta answer|passThrough
#   answer:      responde "Uva" pela ilha; o resultado do claude tem de trazer "Uva".
#   passThrough: devolve a pergunta ao app; em 3 s não pode aparecer pedido de permissão da mesma
#                sessão (o PermissionRequest de AskUserQuestion que vem depois não é segurado). O
#                Claude Code pode então negar ou dar erro: vale qualquer fim (15 s depois da checagem,
#                o teste encerra o claude se ele ainda estiver rodando).
case_pergunta() {
  local mode="$1"
  local dir="$TMP/pergunta-$mode"
  mkdir -p "$dir"
  local real; real="$(cd "$dir" && pwd -P)"
  local out="$TMP/saida-pergunta-$mode.json"
  local prompt="Use a ferramenta AskUserQuestion para me fazer exatamente uma pergunta: \"Qual fruta você prefere?\", com cabeçalho \"Fruta\", escolha única e exatamente duas opções, com os rótulos \"Manga\" e \"Uva\". Depois da minha resposta, responda só com o rótulo da fruta escolhida. Se a ferramenta falhar ou for negada, não pergunte de novo: responda só: sem resposta"

  [[ -f "$TMP/pergunta.py" ]] || write_question_driver
  ACTIVE_REAL="$real"
  # --strict-mcp-config sem config: nenhum servidor MCP, contexto pequeno (custa centavos).
  (cd "$dir" && exec python3 "$TMP/pergunta.py" "$out" "$prompt" claude -p --model haiku --permission-mode default \
    --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio \
    --tools AskUserQuestion --strict-mcp-config --max-turns 4 --plugin-dir "$ROOT/plugin" \
    2>"$TMP/erro-pergunta-$mode.txt") &
  CLAUDE_PID=$!

  local asked=0 seen=" " id title deadline=$((SECONDS + 120)) watch_until=0 extra_permission="" reasked=0
  while kill -0 "$CLAUDE_PID" 2>/dev/null && (( SECONDS < deadline )); do
    # Devolvida: espera o fim por mais 15 s depois da checagem; depois disso o teste encerra o claude.
    (( watch_until > 0 && SECONDS > watch_until + 15 )) && break
    while IFS=$'\t' read -r id title; do
      [[ -z "$id" || "$seen" == *" $id "* ]] && continue
      seen+="$id "
      if (( asked == 0 )); then
        asked=1
        if [[ "$mode" == "answer" ]]; then
          answer_question "$id" "$title" "Uva" || true
        else
          answer "$id" passThrough || true
          watch_until=$((SECONDS + 3))
        fi
      else
        # O modelo perguntou de novo: devolve também, para o claude -p terminar.
        reasked=$((reasked + 1))
        answer "$id" passThrough || true
      fi
    done < <(pending_requests "$real" questions title)
    if (( watch_until > 0 && SECONDS <= watch_until )); then
      for id in $(pending_permissions "$real"); do
        extra_permission="$id"
        answer "$id" passThrough || true
      done
    fi
    sleep 0.2
  done
  # Nos 3 s depois de devolver, mesmo que o claude já tenha saído.
  while (( watch_until > 0 && SECONDS <= watch_until )); do
    for id in $(pending_permissions "$real"); do extra_permission="$id"; answer "$id" passThrough || true; done
    sleep 0.2
  done
  local stopped=0
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null || true
    wait "$CLAUDE_PID" 2>/dev/null || true
    CLAUDE_PID=""
    if [[ "$mode" == "answer" || "$watch_until" == 0 ]]; then
      echo "FALHOU (pergunta/$mode): o claude não terminou em 120 s (perguntas vistas: $asked)"
      head -c 600 "$out" 2>/dev/null || true; head -c 600 "$TMP/erro-pergunta-$mode.txt" 2>/dev/null || true
      return 1
    fi
    stopped=1
  fi
  wait "$CLAUDE_PID" 2>/dev/null || true
  CLAUDE_PID=""
  ACTIVE_REAL=""

  if (( asked == 0 )); then
    echo "FALHOU (pergunta/$mode): nenhuma pergunta apareceu em $REQUESTS para $real"
    head -c 600 "$out" 2>/dev/null || true; head -c 600 "$TMP/erro-pergunta-$mode.txt" 2>/dev/null || true
    return 1
  fi
  local result
  result="$(python3 - "$out" <<'PY' || true
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("result", "")[:200].replace("\n", " "))
except Exception:
    pass
PY
)"
  if [[ "$mode" == "answer" ]]; then
    if [[ "$result" == *Uva* ]]; then
      echo "PASSOU (pergunta/responder): respondida \"Uva\" pela ilha; o claude respondeu: $result"
      return 0
    fi
    echo "FALHOU (pergunta/responder): a saída não traz \"Uva\": $result"
    head -c 800 "$out" 2>/dev/null || true
    return 1
  fi
  if [[ -n "$extra_permission" ]]; then
    echo "FALHOU (pergunta/devolver): depois de devolver, a ilha segurou um pedido de permissão da mesma sessão ($extra_permission)"
    return 1
  fi
  local finish="${result:-(sem result)}"
  (( stopped )) && finish="ainda rodando 15 s depois da checagem, encerrado pelo teste"
  echo "PASSOU (pergunta/devolver): devolvida ao app; nenhum pedido novo de permissão em 3 s$( (( reasked )) && echo "; o modelo perguntou de novo $reasked vez(es), devolvida(s) também"); fim do claude: $finish"
  return 0
}

STATUS=0
if [[ "$CASE" == "concluido" || "$CASE" == "tudo" ]]; then
  case_concluido || STATUS=1
fi
if [[ "$CASE" == "permissao" || "$CASE" == "tudo" ]]; then
  case_permissao allow || STATUS=1
  case_permissao deny || STATUS=1
fi
if [[ "$CASE" == "pergunta" || "$CASE" == "tudo" ]]; then
  case_pergunta answer || STATUS=1
  case_pergunta passThrough || STATUS=1
fi
exit "$STATUS"
