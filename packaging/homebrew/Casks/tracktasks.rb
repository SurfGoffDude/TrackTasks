# Шаблон cask для tap (репозиторий homebrew-<имя>, файл Casks/tracktasks.rb).
# version и sha256 обновляет tools/update-cask.sh; OWNER заменить один раз при создании tap.
cask "tracktasks" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/OWNER/TrackTasks/releases/download/v#{version}/TrackTasks-#{version}.zip"
  name "TrackTasks"
  desc "Локальный трекер задач для проектов с агентами Claude Code и Codex"
  homepage "https://github.com/OWNER/TrackTasks"

  depends_on macos: ">= :tahoe" # macOS 26

  app "TrackTasks.app"
  binary "#{appdir}/TrackTasks.app/Contents/Helpers/tt"

  # Только данные самого приложения. Папки проектов, tasks/*.md, about.md и spectrack.md не трогаются.
  # Идентификатор в путях должен совпадать с CFBundleIdentifier из Info.plist релиза.
  zap trash: [
    "~/Library/Application Support/TrackTasks",
    "~/Library/Caches/io.github.surfgoffdude.TrackTasks",
    "~/Library/Preferences/io.github.surfgoffdude.TrackTasks.plist",
    "~/Library/Saved Application State/io.github.surfgoffdude.TrackTasks.savedState",
  ]
end
