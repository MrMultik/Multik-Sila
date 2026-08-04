; Установщик Multik Sila. Собирается из release-сборки Flutter.
;
; Собрать:
;   flutter build windows --release
;   tools\innosetup\ISCC.exe installer\multik_sila.iss
; Результат: installer\output\MultikSila-<версия>-setup.exe
;
; Версию правим ЗДЕСЬ и в kAppVersion в lib/main.dart — они не связаны
; автоматически, и разъехавшиеся номера сломают самообновление приложения.

#define AppName "Multik Sila"
#define AppVersion "1.0.1"
#define AppExeName "proxy_app_test.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
; AppId менять НЕЛЬЗЯ: по нему Windows отличает обновление от новой установки.
; Другой AppId — и рядом появится вторая копия вместо обновления существующей.
AppId={{8F3A9C21-4B7E-4D62-9E15-2A6C8D5F1B03}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Multik Sila
DefaultDirName={localappdata}\Programs\Multik Sila
DefaultGroupName=Multik Sila
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=MultikSila-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Ставим в профиль пользователя, а НЕ в Program Files. Причина проверена на
; живой установке: приложение хранит рабочие файлы (конфиги ядра, лог, наборы
; правил, мосты) рядом с собой, а в Program Files без прав администратора
; писать нельзя — config.json не создавался, и ядро не стартовало вообще.
; Заодно установка перестала требовать UAC, а автообновление ядер получило
; право заменить .exe ядра на месте.
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
; Заявляем совместимость с Windows 10 и новее: TUN-адаптер и wintun на более
; старых системах не проверялись.
MinVersion=10.0

[Languages]
; Лицензия своя на каждый язык: Inno сначала спрашивает язык, потом показывает
; соглашение — читать его человек должен на том языке, который выбрал.
; Файлы обязаны быть в UTF-8 С BOM: без BOM Inno читает их в кодировке языка,
; и кириллица приезжает мусором.
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"; LicenseFile: "license_ru.txt"
Name: "english"; MessagesFile: "compiler:Default.isl"; LicenseFile: "license_en.txt"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Само приложение: перезаписываем ВСЕГДА и без оглядки на версии файлов —
; при обновлении поверх старой установки должны замениться и exe, и dll,
; и содержимое data (там лежат ассеты сборки, включая наборы правил).
;
; Excludes ОБЯЗАТЕЛЕН и держится в актуальном состоянии. Папка Release — это
; ещё и рабочий каталог приложения при запуске из сборки: туда ложатся
; config.json и конфиги мостов с РЕАЛЬНЫМИ адресами серверов, UUID и паролями
; из подписки, лог со всей историей соединений и кэш наборов правил. Без
; исключений всё это запекается внутрь setup.exe и уезжает каждому, кто его
; скачает. Поймано перед первой публикацией на GitHub.
; Каждый шаблон начинается с "\" — это ЯКОРЬ НА КОРЕНЬ папки сборки. Без него
; Inno применяет шаблон на любом уровне вложенности, и `rulesets\*` вырезал не
; только рабочий кэш рядом с .exe, но и вшитые в сборку наборы правил
; `data\flutter_assets\assets\rulesets\*.srs` — раздельное туннелирование
; поехало бы к людям без единого набора и молча выродилось в «всё через VPN».
; Поймано проверкой списка файлов в собранном пакете, а не глазами.
Source: "{#BuildDir}\*"; DestDir: "{app}"; \
    Excludes: "\sing-box.exe,\xray.exe,\config.json,\xray_config.json,\xray_bridge_*.json,\*_probe.json,\app_log.txt,\app_log.txt.*,\capture.txt,\*.new,\*.bak,\rulesets\*,\update_staging\*,\backup_*\*"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

; Ядра — ТОЛЬКО если их ещё нет. Приложение обновляет их само, и к моменту
; следующей установки на машине вполне может лежать версия новее той, что
; вшита в дистрибутив. С ignoreversion установщик молча откатил бы ядро
; назад, а автообновление потом не подняло бы его обратно: оно обновляет
; только вперёд по версии.
Source: "{#BuildDir}\sing-box.exe"; DestDir: "{app}"; Flags: onlyifdoesntexist
Source: "{#BuildDir}\xray.exe"; DestDir: "{app}"; Flags: onlyifdoesntexist

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Рабочие файлы, которые приложение создаёт РЯДОМ С СОБОЙ уже после установки.
; Инсталлятор о них не знает, и без этой секции после удаления осталась бы
; папка с конфигами, логом и наборами правил.
Type: files; Name: "{app}\config.json"
Type: files; Name: "{app}\xray_config.json"
Type: files; Name: "{app}\xray_bridge_*.json"
Type: files; Name: "{app}\*_probe.json"
Type: files; Name: "{app}\app_log.txt"
Type: files; Name: "{app}\app_log.txt.prev.txt"
Type: files; Name: "{app}\sing-box.exe.new"
Type: files; Name: "{app}\sing-box.exe.bak"
Type: files; Name: "{app}\xray.exe.new"
Type: files; Name: "{app}\xray.exe.bak"
Type: filesandordirs; Name: "{app}\rulesets"
Type: filesandordirs; Name: "{app}\update_staging"
Type: dirifempty; Name: "{app}"
; Если папка установки оказалась недоступна на запись (например, приложение
; всё-таки поставили в Program Files), рабочие файлы уходят сюда — чистим и там.
Type: filesandordirs; Name: "{userappdata}\Multik Sila"

[Code]
// Перед установкой и перед удалением приложение должно быть закрыто: иначе
// файлы заняты, а в TUN-режиме на машине останется поднятый адаптер и
// подменённый системный прокси. Просим закрыть, а не убиваем: у работающего
// приложения есть корректный выход, который возвращает настройки системы.
function IsAppRunning(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec('cmd.exe', '/c tasklist /FI "IMAGENAME eq {#AppExeName}" | find /I "{#AppExeName}"',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if IsAppRunning() then
    Result := 'Multik Sila сейчас запущена. Закройте её через меню в трее' + #13#10 +
              '(правая кнопка по значку — «Выход») и повторите установку.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  if IsAppRunning() then
  begin
    MsgBox('Multik Sila сейчас запущена. Закройте её через меню в трее' + #13#10 +
           '(правая кнопка по значку — «Выход») и повторите удаление.',
           mbError, MB_OK);
    Result := False;
  end;
end;
