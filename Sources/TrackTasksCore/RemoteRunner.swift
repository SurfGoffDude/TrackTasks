import Foundation

/// The script that works on the server. It doesn't need the connection: events, exit code and result stay in files.
///
///     bin/…                     this script (one file per version)
///     repos/<project>.git       bare repository
///     work/<work>/code          working copy, work/<work>/project — tracker files
///     runs/<run>/               up/ (uploaded), in/ (messages to claude), out.jsonl, err, done, result.bundle, task.md
public enum RemoteRunner {
    public static var fileName: String { "run-\(RemoteRun.sha256(Data(script.utf8)).prefix(16)).sh" }

    /// Exit codes of operations.
    public static let noGit: Int32 = 71, noClaude: Int32 = 72, badUpload: Int32 = 73, taken: Int32 = 74, noRun: Int32 = 75

    public static let script = #"""
    #!/bin/sh
    # TrackTasks
    umask 077
    cd "$(dirname "$0")/.." || exit 90
    ROOT=$(pwd -P) || exit 90
    SELF=$ROOT/bin/$(basename "$0")
    PATH=$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH
    export PATH
    unset LC_ALL CDPATH CLAUDECODE CLAUDE_CODE_ENTRYPOINT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    GIT_TERMINAL_PROMPT=0; GIT_CONFIG_COUNT=2
    GIT_CONFIG_KEY_0=core.hooksPath; GIT_CONFIG_VALUE_0=/dev/null
    GIT_CONFIG_KEY_1=core.fsmonitor; GIT_CONFIG_VALUE_1=false
    quiet_git() { GIT_CONFIG_COUNT=$GIT_CONFIG_COUNT GIT_CONFIG_KEY_0=$GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0=$GIT_CONFIG_VALUE_0 \
        GIT_CONFIG_KEY_1=$GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1=$GIT_CONFIG_VALUE_1 GIT_TERMINAL_PROMPT=0 git "$@"; }
    op=$1; shift

    id() { case $1 in ''|*[!A-Za-z0-9_-]*) echo "bad id" >&2; exit 91;; esac; }
    num() { case $1 in ''|*[!0-9]*) echo "bad number" >&2; exit 91;; esac; }
    name() { case $1 in code.bundle|prompt|system|model|argv|vars|task|about|spec) ;; *) exit 91;; esac; }
    size() { wc -c < "$1" | tr -d ' '; }
    sha() {
        if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"
        elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"
        else openssl dgst -sha256 -r < "$1"; fi | cut -d' ' -f1
    }
    started() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null; }
    # The pid may be taken by another program: the start time is compared too.
    alive() {
        [ -s "$1" ] || return 1
        read -r p < "$1"
        kill -0 "$p" 2>/dev/null && [ "$(started "$p")" = "$(sed -n 2p "$1")" ]
    }
    remember() { { echo "$1"; started "$1"; } > "$2.tmp" && mv -f "$2.tmp" "$2"; }
    tree() {
        ps -A -o pid= -o ppid= | awk -v r="$1" '{p[$1]=$2} END{k[r]=1; do{c=0; for(i in p) if(!(i in k) && (p[i] in k)){k[i]=1;c=1}}while(c); for(i in k) print i}'
    }
    kill_tree() {
        all=$(tree "$1")
        kill -TERM -- "-$1" 2>/dev/null
        for p in $all; do kill -TERM "$p" 2>/dev/null; done
        n=0
        while [ $n -lt 5 ]; do
            left=
            for p in $all; do kill -0 "$p" 2>/dev/null && left=1; done
            [ -z "$left" ] && break
            sleep 1; n=$((n+1))
        done
        kill -KILL -- "-$1" 2>/dev/null
        for p in $all; do kill -KILL "$p" 2>/dev/null; done
    }
    # A process group of its own, input from fd 3; the pid is in $!.
    spawn() {
        if command -v setsid >/dev/null 2>&1; then setsid "$@" <&3 3<&- &
        elif command -v perl >/dev/null 2>&1; then perl -e 'use POSIX; POSIX::setsid(); exec {$ARGV[0]} @ARGV or exit 127' "$@" <&3 3<&- &
        else set -m; "$@" <&3 3<&- & set +m; fi
    }
    detach() { nohup "$@" >/dev/null 2>&1 </dev/null & }
    stop_run() {
        [ -d "$ROOT/runs/$1" ] || return 0
        : > "$ROOT/runs/$1/cancel"
        if alive "$ROOT/runs/$1/child"; then kill_tree "$(sed -n 1p "$ROOT/runs/$1/child")"; fi
    }

    # ---- inside the runner ----
    ERR=; EXIT=0; CLAUDE_STARTED=0
    fail() { [ -n "$ERR" ] || ERR=$(printf '%s' "$1" | tr '\n\r' '  ' | cut -c1-600); return 1; }
    finish() {
        cancelled=0; [ -e "$RUN/cancel" ] && cancelled=1
        bundle=none; task=none
        [ -f "$RUN/result.bundle" ] && bundle="$(size "$RUN/result.bundle") $(sha "$RUN/result.bundle")"
        [ -f "$RUN/task.md" ] && task="$(size "$RUN/task.md") $(sha "$RUN/task.md")"
        out=0; [ -f "$RUN/out.jsonl" ] && out=$(size "$RUN/out.jsonl")
        # No space: wait for it rather than lose the result.
        until { echo "exit=$EXIT"; echo "cancelled=$cancelled"; echo "claude=$CLAUDE_STARTED"; echo "out=$out"; echo "bundle=$bundle"; echo "task=$task"; echo "error=$ERR"; echo end=1; } > "$RUN/done.tmp" \
            && [ "$(tail -n 1 "$RUN/done.tmp")" = end=1 ] && mv -f "$RUN/done.tmp" "$RUN/done"; do [ -d "$RUN" ] || exit 1; sleep 20; done
    }
    conf() { echo "WORK=$WORK PROJ=$PROJ MODE=$MODE BASE=$BASE"; }
    collect() {
        code=$ROOT/work/$WORK/code; repo=$ROOT/repos/$PROJ.git
        if [ -n "$TASK" ] && [ -f "$ROOT/work/$WORK/project/tasks/$TASK" ]; then
            cp "$ROOT/work/$WORK/project/tasks/$TASK" "$RUN/task.tmp" && mv -f "$RUN/task.tmp" "$RUN/task.md" || fail "не удалось сохранить файл задачи: нет места?"
        fi
        [ "$MODE" = coding ] || return 0
        GIT_INDEX_FILE=$RUN/index; export GIT_INDEX_FILE
        rm -f "$RUN/index" "$RUN/index.lock"
        msg=$(cd "$code" 2>&1 && quiet_git read-tree "$BASE" 2>&1 && quiet_git -c core.safecrlf=false add -A -- . ':(exclude)tasks' ':(exclude)about.md' ':(exclude,icase)spectrack.md' ':(exclude).claude' ':(exclude,glob)automations/*.md' \
            ':(exclude)node_modules' ':(exclude).venv' ':(exclude)venv' ':(exclude)vendor' ':(exclude)Pods' ':(exclude).env' ':(exclude).env.local' ':(exclude).env.development' 2>&1) \
            || { unset GIT_INDEX_FILE; fail "не удалось собрать результат: $msg"; return 1; }
        t=$(cd "$code" && quiet_git write-tree 2>>"$RUN/err")
        unset GIT_INDEX_FILE
        rm -f "$RUN/index"
        [ -n "$t" ] || { fail "не удалось собрать результат (write-tree)"; return 1; }
        c=$(echo "TrackTasks result $ID" | quiet_git -C "$repo" -c user.name=TrackTasks -c user.email=tracktasks@localhost commit-tree "$t" -p "$BASE" 2>>"$RUN/err")
        [ -n "$c" ] || { fail "не удалось собрать результат (commit-tree)"; return 1; }
        msg=$(quiet_git -C "$repo" update-ref "refs/tt/result/$ID" "$c" 2>&1 && quiet_git -C "$repo" bundle create "$RUN/bundle.tmp" "refs/tt/result/$ID" "^$BASE" 2>&1 && mv -f "$RUN/bundle.tmp" "$RUN/result.bundle" 2>&1) \
            || { rm -f "$RUN/bundle.tmp"; fail "не удалось собрать результат: $msg"; return 1; }
    }
    prepare() {
        work=$ROOT/work/$WORK; code=$work/code; repo=$ROOT/repos/$PROJ.git
        mkdir -p "$work/project/tasks" || { fail "не удалось создать папку: нет места?"; return 1; }
        if [ -s "$work/run" ]; then
            old=$(cat "$work/run")
            if [ "$old" != "$ID" ] && [ -d "$ROOT/runs/$old" ]; then
                if alive "$ROOT/runs/$old/pid" && [ ! -e "$ROOT/runs/$old/done" ]; then
                    stop_run "$old"
                    n=0
                    while [ ! -e "$ROOT/runs/$old/done" ]; do n=$((n+1)); [ $n -gt 60 ] && { fail "в рабочей копии ещё идёт прежний запуск"; return 1; }; sleep 1; done
                fi
            fi
        fi
        echo "$ID" > "$work/run" || { fail "нет места на диске"; return 1; }
        msg=$(quiet_git -C "$repo" bundle verify -q "$RUN/up/code.bundle" 2>&1 && quiet_git -C "$repo" fetch -q --no-tags "$RUN/up/code.bundle" "+refs/tracktasks/remote/$ID/base:refs/tt/work/$WORK" 2>&1) || { fail "код не принят: $msg"; return 1; }
        [ "$(quiet_git -C "$repo" rev-parse "refs/tt/work/$WORK")" = "$BASE" ] || { fail "код не принят: другой коммит"; return 1; }
        quiet_git -C "$repo" update-ref refs/tt/last "$BASE"
        if [ ! -e "$code/.git" ]; then
            rm -rf "$code"; quiet_git -C "$repo" worktree prune
            msg=$(quiet_git -C "$repo" worktree add -q --detach "$code" "$BASE" 2>&1) || { fail "рабочая копия не создана: $msg"; return 1; }
        else
            rm -f "$(quiet_git -C "$code" rev-parse --absolute-git-dir)/index.lock"
            msg=$(quiet_git -C "$code" checkout -q -f --detach "$BASE" 2>&1 && quiet_git -C "$code" clean -ffdq -e .claude 2>&1) || { fail "рабочая копия не обновлена: $msg"; return 1; }
        fi
        for f in "about about.md" "spec spectrack.md"; do
            set -- $f
            rm -f "$work/project/$2"
            [ -f "$RUN/up/$1" ] && { cp "$RUN/up/$1" "$work/project/$2" || { fail "нет места на диске"; return 1; }; }
        done
        if [ -n "$TASK" ] && [ -f "$RUN/up/task" ]; then cp "$RUN/up/task" "$work/project/tasks/$TASK" || { fail "нет места на диске"; return 1; }; fi
        return 0
    }
    child() {
        remember "$1" "$RUN/child"
        [ -e "$RUN/cancel" ] && kill_tree "$1"
        wait "$1"; EXIT=$?
        rm -f "$RUN/child"
    }
    setup() {
        [ -n "$SETUP" ] && [ "$MODE" = coding ] || return 0
        mark=$ROOT/work/$WORK/setup-done
        [ -f "$mark" ] && [ "$(cat "$mark")" = "$SETUP" ] && return 0
        cd "$ROOT/work/$WORK/code" || return 1
        TRACKTASKS_MAIN=$ROOT/work/$WORK/project TRACKTASKS_WORKTREE=$ROOT/work/$WORK/code TRACKTASKS_BRANCH=$BRANCH CI=1
        export TRACKTASKS_MAIN TRACKTASKS_WORKTREE TRACKTASKS_BRANCH CI
        spawn /bin/sh -lc "$SETUP" 3</dev/null >"$RUN/setup.log" 2>&1
        child $!
        unset CI
        cd "$RUN" || return 1
        [ "$EXIT" = 0 ] || { [ -e "$RUN/cancel" ] || fail "setup на сервере не прошёл ($EXIT): $(tail -c 500 "$RUN/setup.log")"; return 1; }
        printf '%s' "$SETUP" > "$mark"
    }
    # Messages go to claude in order; its input stays open until the result.
    feed() {
        n=1
        while :; do
            f=$RUN/in/$(printf %06d $n).json
            if [ -f "$f" ]; then cat "$f"; n=$((n+1)); continue; fi
            tail -n 5 "$RUN/out.jsonl" 2>/dev/null | grep -q '^{"type":"result"' && return 0
            [ -e "$RUN/input-end" ] && return 0
            [ -d "$RUN" ] || return 0
            sleep 1
        done
    }
    claude_run() {
        rm -f "$RUN/fifo"
        mkfifo "$RUN/fifo" || { fail "не удалось создать канал"; return 1; }
        set --
        . "$RUN/up/argv"
        cd "$ROOT/work/$WORK/code" || return 1
        : > "$RUN/out.jsonl"
        ( trap '' PIPE; feed > "$RUN/fifo" ) & feeder=$!
        remember "$feeder" "$RUN/feeder"
        CLAUDE_STARTED=1
        : > "$RUN/claude-started"
        spawn "$CLAUDE" "$@" 3<"$RUN/fifo" >>"$RUN/out.jsonl" 2>"$RUN/err"
        child $!
        kill "$feeder" 2>/dev/null
        wait "$feeder" 2>/dev/null
        cd "$RUN" || return 1
        return 0
    }

    case $op in
    check)
        echo "root=$ROOT"
        command -v git >/dev/null 2>&1 || exit 71
        echo "git=$(git --version)"
        v=$("$1" --version </dev/null 2>/dev/null) || exit 72
        echo "claude=$v" ;;
    repo)
        id "$1"; r=repos/$1.git
        [ -f "$r/HEAD" ] || { mkdir -p repos && quiet_git init -q --bare "$r" || exit 1; }
        quiet_git -C "$r" for-each-ref --format='%(objectname)' ;;
    size)
        id "$1"; name "$2"; mkdir -p "runs/$1/up" "runs/$1/in" || exit 1
        if [ -f "runs/$1/up/$2" ]; then echo sealed; elif [ -f "runs/$1/up/$2.part" ]; then size "runs/$1/up/$2.part"; else echo 0; fi ;;
    append)
        id "$1"; name "$2"; cat >> "runs/$1/up/$2.part" ;;
    seal)
        id "$1"; name "$2"; num "$3"; f=runs/$1/up/$2
        [ -f "$f" ] && [ ! -f "$f.part" ] && [ "$(sha "$f")" = "$4" ] && exit 0
        [ -f "$f.part" ] && [ "$(size "$f.part")" = "$3" ] && [ "$(sha "$f.part")" = "$4" ] && mv -f "$f.part" "$f" && exit 0
        rm -f "$f.part" "$f"; exit 73 ;;
    put)
        id "$1"; num "$2"; d=runs/$1/in; f=$d/$(printf %06d "$2").json; t=$d/new-$$
        cat > "$t" || exit 1
        [ "$(size "$t")" = "$3" ] || { rm -f "$t"; exit 73; }
        if ln "$t" "$f" 2>/dev/null; then rm -f "$t"; exit 0; fi
        if cmp -s "$t" "$f"; then rm -f "$t"; exit 0; fi
        rm -f "$t"; exit 74 ;;
    start)
        id "$1"; id "$2"; id "$3"; id "$5"
        [ -d "runs/$1/up" ] || exit 75
        [ -d "runs/$1/lock" ] && exit 0
        ( cd / && exec 3</dev/null && spawn nohup /bin/sh "$SELF" run "$@" >/dev/null 2>&1 )
        n=0
        while [ ! -s "runs/$1/pid" ]; do n=$((n+1)); [ $n -gt 20 ] && exit 1; sleep 1; done ;;
    run)
        ID=$1 WORK=$2 PROJ=$3 MODE=$4 BASE=$5 CLAUDE=$6 RUN=$ROOT/runs/$1
        trap '' HUP
        cd "$RUN" && mkdir lock 2>/dev/null || exit 0
        conf > conf
        remember $$ pid
        TASK= SETUP= BRANCH=
        . "$RUN/up/vars"
        if [ ! -e cancel ] && prepare && setup && [ ! -e cancel ]; then
            claude_run
            echo "$EXIT" > exit
        fi
        if [ -f "$RUN/claude-started" ]; then collect; fi
        finish ;;
    recover)
        # The runner died (reboot): save what is left.
        ID=$1 RUN=$ROOT/runs/$1
        cd "$RUN" && [ ! -e done ] || exit 0
        remember $$ pid
        if alive child; then kill_tree "$(sed -n 1p child)"; fi
        if alive feeder; then kill "$(sed -n 1p feeder)"; fi
        . ./conf; TASK= SETUP= BRANCH=; . up/vars
        EXIT=1
        if [ -s exit ]; then EXIT=$(cat exit); else ERR="запуск на сервере оборвался (перезагрузка?)"; fi
        [ -f claude-started ] && { CLAUDE_STARTED=1; collect; }
        finish ;;
    again)
        # The result could not be saved (no space): try once more.
        id "$1"; [ -d "runs/$1/lock" ] || exit 75
        alive "runs/$1/pid" || rm -f "runs/$1/done" ;;
    follow)
        id "$1"; num "$2"; off=$2; R=runs/$1; me=$PPID
        [ -d "$R/lock" ] || exit 75
        while :; do
            end=0; [ -e "$R/done" ] && end=1
            s=0; [ -f "$R/out.jsonl" ] && s=$(size "$R/out.jsonl")
            if [ "$s" -gt "$off" ]; then
                tail -c "+$((off+1))" "$R/out.jsonl" | head -c $((s-off)) || exit 1
                off=$s; continue
            fi
            [ $end = 1 ] && exit 0
            if [ -f "$R/pid" ] && ! alive "$R/pid" && [ ! -e "$R/done" ]; then
                ( cd / && exec 3</dev/null && spawn nohup /bin/sh "$SELF" recover "$1" >/dev/null 2>&1 ); sleep 2
            fi
            # The connection is gone.
            [ "$(ps -o ppid= -p $$ | tr -d ' ')" = "$me" ] || exit 1
            sleep 1
        done ;;
    state)
        id "$1"; R=runs/$1
        [ -d "$R" ] || exit 75
        [ -d "$R/lock" ] && echo lock=1
        n=0; for f in "$R"/in/*.json; do [ -f "$f" ] && n=$((n+1)); done
        echo "in=$n"
        cat "$R"/in/*.json 2>/dev/null | grep -o '"request_id":"[^"]*"' | sed 's/^/answered=/'
        [ -f "$R/done" ] && cat "$R/done"
        exit 0 ;;
    fetch)
        id "$1"; num "$3"
        case $2 in result.bundle|task.md|err) ;; *) exit 91;; esac
        [ -f "runs/$1/$2" ] || exit 75
        tail -c "+$(($3+1))" "runs/$1/$2" ;;
    end)
        id "$1"; [ -d "runs/$1" ] && : > "runs/$1/input-end" ;;
    stop)
        id "$1"; [ -d "runs/$1" ] || exit 0
        ID=$1 RUN=$ROOT/runs/$1
        : > "$RUN/cancel" || exit 1
        # Not started yet: it never will.
        if mkdir "$RUN/lock" 2>/dev/null; then cd "$RUN" && finish; exit 0; fi
        stop_run "$1"
        exit 0 ;;
    rmrun)
        id "$1"; id "$2"
        alive "runs/$1/pid" && [ ! -e "runs/$1/done" ] && exit 1
        rm -rf "runs/$1" || exit 1
        [ -d "repos/$2.git" ] && quiet_git -C "repos/$2.git" update-ref -d "refs/tt/result/$1" 2>/dev/null
        exit 0 ;;
    rmwork)
        id "$1"; id "$2"
        if [ -s "work/$1/run" ]; then
            r=$(cat "work/$1/run"); id "$r"
            alive "runs/$r/pid" && [ ! -e "runs/$r/done" ] && exit 1
        fi
        rm -rf "work/$1" || exit 1
        if [ -d "repos/$2.git" ]; then
            quiet_git -C "repos/$2.git" worktree prune
            quiet_git -C "repos/$2.git" update-ref -d "refs/tt/work/$1" 2>/dev/null
        fi
        exit 0 ;;
    *) exit 92 ;;
    esac
    """# + "\n"
}

/// What `state` prints.
public struct RemoteState: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var size: Int
        public var sha: String
    }
    /// Contents of `done`.
    public struct Done: Equatable, Sendable {
        public var exit: Int32 = 0
        public var cancelled = false
        public var claudeStarted = false
        public var out = 0
        public var bundle: File?
        public var task: File?
        public var error = ""
    }

    public var started = false
    /// Messages to claude written so far.
    public var inputs = 0
    /// Requests that already have an answer there.
    public var answered: Set<String> = []
    public var done: Done?

    public init(_ text: String) {
        var d = Done(), ended = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let v = String(line[line.index(after: eq)...])
            func file() -> File? {
                let p = v.split(separator: " ")
                guard p.count == 2, let n = Int(p[0]), n >= 0, RemoteServer.matches(String(p[1]), "[0-9a-f]{64}") else { return nil }
                return File(size: n, sha: String(p[1]))
            }
            switch line[..<eq] {
            case "lock": started = v == "1"
            case "in": inputs = Int(v) ?? 0
            case "answered":
                // `"request_id":"…"`
                let p = v.split(separator: "\"")
                if p.count == 3 { answered.insert(String(p[2])) }
            case "exit": d.exit = Int32(v) ?? 1
            case "cancelled": d.cancelled = v == "1"
            case "claude": d.claudeStarted = v == "1"
            case "out": d.out = Int(v) ?? 0
            case "bundle": d.bundle = file()
            case "task": d.task = file()
            case "error": d.error = v
            case "end": ended = v == "1"
            default: break
            }
        }
        if ended { done = d }
    }
}
