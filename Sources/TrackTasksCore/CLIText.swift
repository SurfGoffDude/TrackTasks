extension CLI {
    static let help = """
        tt — задачи TrackTasks из терминала (tasks/*.md); приложение нужно только для tt queue

        tt list [--status todo,doing,done] [--priority …] [--size …] [--ready] [--all] [--watch]
        tt board [--priority …] [--size …] [--all] [--watch]   в терминале — интерактивная доска (стрелки/hjkl, H/L или 1–3 — статус, q), иначе текст
        tt search <слова> [--status …] [--priority …] [--size …] [--all] [--watch]
        tt show <задача> [--watch]
        tt add <название> [--priority high|medium|low] [--size s|m|l] [--agent профиль] [--depends a,b]
               [--files путь,папка/] [--repos репозиторий,…] [--verify команда] [--body текст | --body -] [--item пункт]… [--criterion условие]… [--force]
        tt edit <задача> [--title …] [--status …] [--priority …] [--size s|m|l|none] [--agent профиль|none]
                [--depends a,b|none] [--add-depend a] [--rm-depend a] [--files a,b/|none] [--repos a,b|none] [--verify команда|none] [--body текст | --body -]
                [--check N,M] [--uncheck N] [--item …]… [--criterion …]… [--note …]… [--if-rev rev] [--force]
        tt done <задача> [--note …] [--if-rev rev] [--force]
        tt queue list [--all] [--project …]          активные и ждущие слияния; --all — и завершённые
        tt queue add <задача>… [--with-deps]         поставить в очередь Claude (--with-deps — и незакрытые зависимости)
        tt queue cancel <job>
        tt queue answer <job> <текст | ->            сообщение агенту завершённого job
        tt queue log <job> [--tail N]
        tt queue open                                показать очередь в приложении
        tt mcp               MCP-сервер по stdio; tt mcp --config — строки для Claude Code и Codex
        tt instructions      инструкция для агентов
        tt help | tt --version

        <задача>             имя файла, его однозначная часть или путь tasks/….md
        <job>                id из tt queue list (можно начало) или имя файла задачи
        -p, --project        папка проекта или её имя; по умолчанию — проект текущей папки
        -a, --all            все проекты из папки проектов (TT_ROOT, иначе настройка приложения, иначе ~/Projects)
        --json               JSON в stdout (schema: 1), ошибки тоже; с --watch — документ на строку
        --watch              печатать заново при изменении файлов, до Ctrl-C
        --force              закрыть с невыполненными критериями, допустить дубль названия
        list показывает открытые задачи; --ready — только todo без незакрытых зависимостей

        Коды выхода: 0 успех, 1 ошибка чтения/записи, 2 неверные аргументы, 3 не найдено или неоднозначно,
        4 файл изменился с момента чтения или состояние очереди не позволяет,
        5 неверные данные (цикл, дубль, невыполненные критерии, битый frontmatter), 6 приложение не запущено или другой версии

        """

    static let instructions = """
        # tt — задачи проекта для агентов

        Задачи лежат в tasks/*.md, один файл — одна задача. `tt` читает и пишет их напрямую. Из git worktree
        он работает с задачами основной папки проекта. Не создавай и не переименовывай файлы задач руками.

        ## Порядок
        1. `tt list --ready --json` — задачи, которые можно начать; `tt search <слова> --json` — нет ли уже такой.
        2. `tt show <file> --json` — описание, пункты (`items`), критерии (`criteriaItems`, в них `evidence` — слова агента), `depends`, `rev`.
        3. `tt edit <file> --status doing` — взял в работу.
        4. `tt edit <file> --check 1,2 --note "решение"` — по ходу. Номера — поле `n` (сквозные, с 1).
        5. `tt done <file> --note "итог"` — когда выполнены все критерии готовности; иначе код 5.
           `--force` — только по просьбе человека.

        `tasks/archive/` (только чтение) и `tasks/drafts/` (не выполнять) `tt` не показывает, но `--depends` принимает
        полное имя файла оттуда: архивная done считается выполненной.

        ## Новая задача
        `tt add "Название" --priority high --size m --depends <file> --body "Что и зачем" --item "шаг" --criterion "проверка"`
        - Длинное описание — `--body -` из stdin. Значение, начинающееся с «--», пиши как `--note=--текст`.
        - Одна задача — один проверяемый результат. Порядок — только через `--depends`, не текстом.
        - `--files Sources/A.swift,Tests/` — что задача изменит: пересекающиеся задачи очередь не запускает вместе.
        - `--repos work/api` — другие репозитории, которые задача тоже меняет; пути внутри корня проектов.
        - `--verify "команда"` — своя проверка задачи после проверки проекта; только если команду назвал человек.
          Выполнится после того, как человек подтвердит её текст в приложении. Не меняй и не убирай её без просьбы.
        - size: s — простая правка, m — обычная, l — архитектура, миграция, конкурентность.

        ## Очередь
        `tt queue …` обращается к запущенному приложению. Ставь, отменяй и отвечай — только по просьбе человека.
        Разрешения, планы и слияния через `tt` не одобряются. Файл queue.json не правь. После кода 6 с «ответ не получен»
        сначала проверь `tt queue list --all --json`: команда могла выполниться.

        ## JSON
        - С `--json` в stdout всегда один JSON-документ; с `--watch` — один документ на строку.
        - Верхний уровень: `schema` (сейчас 1), `command` и данные: `tasks` (list, search), `columns` (board),
          `task` (show, add, edit, done), `changed` (add, edit, done), `unreadable` (файлы, которые не прочитались);
          queue — `action` и `jobs` (list — ещё `paused`; log — `job` и `log`).
        - Ошибка: `{"schema":1,"command":…,"error":{"code":…,"exit":…,"message":…}}`.
        - Поля задачи: file, path, rev, project, title, status, priority, size, agent, created, completed, depends,
          openDepends (незакрытые), files, repos, verify, checklist и criteria ({done,total}), problems. Пустое значение — null.
        - Новые поля могут появляться без смены schema; незнакомые пропускай.

        ## Коды выхода
        0 успех · 1 io · 2 usage · 3 not_found (или неоднозначно) · 4 conflict · 5 invalid · 6 unavailable

        Правишь по прочитанному раньше — передай `--if-rev <rev>`. Код 4: файл изменили, перечитай
        `tt show` и повтори правку, если она ещё нужна.

        """
}
