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
#define AppVersion "1.0.7"
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
; БЕЗ `skipifsilent` — иначе самообновление оставляет человека без приложения.
;
; Оно запускает этот установщик с `/VERYSILENT` и сразу выходит (см.
; _runInstallerUpdate в main.dart), рассчитывая, что закрытие и подмену файлов
; установщик берёт на себя. Так и есть — но со `skipifsilent` пропускался и
; ЗАПУСК ОБРАТНО, а другого режима самообновление не использует. Наружу это
; выходило так: приложение молча закрылось, файлы обновились, и на экране не
; осталось ничего — ни окна, ни трея. Если при этом работал TUN, машина просто
; оставалась без VPN, ничего об этом не сказав.
;
; Права наследуются от установщика: обновление элевированного приложения
; вернёт его элевированным, и TUN поднимется сам.
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall

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

[CustomMessages]
; Сообщения кода — через CustomMessages, а не строками в [Code]: установщик
; двуязычный, и зашитый русский текст английский пользователь просто не поймёт.
russian.AppRunningAsk=Multik Sila сейчас запущена.%n%nЗакрыть её и продолжить установку?%n%nПриложение завершится штатно: соединение будет разорвано, системные настройки сети возвращены на место.
russian.AppRunningManual=Не удалось закрыть Multik Sila автоматически.%n%nЗакройте её вручную через меню в трее (правая кнопка по значку — «Выход») и запустите установку заново.
russian.AppRunningUninstall=Multik Sila сейчас запущена. Закройте её через меню в трее (правая кнопка по значку — «Выход») и повторите удаление.
russian.RemovingOld=Удаление предыдущей версии...
english.AppRunningAsk=Multik Sila is currently running.%n%nClose it and continue with the installation?%n%nThe app will shut down properly: the connection will be dropped and the system network settings restored.
english.AppRunningManual=Multik Sila could not be closed automatically.%n%nPlease close it manually from the tray menu (right-click the icon and choose Exit), then run the installer again.
english.AppRunningUninstall=Multik Sila is currently running. Close it from the tray menu (right-click the icon and choose Exit), then run the uninstaller again.
english.RemovingOld=Removing the previous version...

[Code]
// Приложение обязано быть закрыто до установки: файлы заняты, а в TUN-режиме
// на машине остаётся поднятый адаптер и подменённый системный прокси.
//
// Убить процесс установщик НЕ МОЖЕТ и не должен. Не может — потому что в
// TUN-режиме приложение работает от администратора, а установщик от обычного
// пользователя (PrivilegesRequired=lowest), и Windows такой taskkill
// запрещает. Не должен — потому что убийство оставит систему с подменённым
// прокси и осиротевшими процессами ядра, которые держат порт и TUN-адаптер.
//
// Поэтому просим само приложение закрыться: стучимся в его сокет одной копии
// (127.0.0.1:17999) командой `quit`. Сокет на петле, поэтому доступен и через
// границу уровней целостности, а приложение по этой команде делает штатный
// выход — останавливает ядро и возвращает настройки сети.
function IsAppRunning(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec('cmd.exe', '/c tasklist /FI "IMAGENAME eq {#AppExeName}" | find /I "{#AppExeName}"',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

// Возвращает True, если приложение закрылось. Ждём до 20 секунд: штатный
// выход останавливает ядро, снимает мосты и возвращает прокси — это не
// мгновенно, а рвать его на половине хуже, чем подождать.
function AskAppToQuit(): Boolean;
var
  ResultCode, I: Integer;
begin
  Exec('powershell.exe',
       '-NoProfile -WindowStyle Hidden -Command "try { $c = New-Object Net.Sockets.TcpClient(''127.0.0.1'', 17999);' +
       ' $b = [Text.Encoding]::ASCII.GetBytes(''quit''); $c.GetStream().Write($b, 0, $b.Length);' +
       ' $c.GetStream().Flush(); $c.Close() } catch {}"',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  for I := 0 to 39 do
  begin
    if not IsAppRunning() then
    begin
      Result := True;
      Exit;
    end;
    Sleep(500);
  end;
  Result := False;
end;

// Полное удаление прошлой версии перед установкой новой, а не перезапись
// поверх. Перезапись оставляет файлы, которых в новой сборке уже нет, и они
// продолжают лежать в папке годами. Профили и настройки лежат в
// %APPDATA%\com.example\proxy_app_test — деинсталлятор туда не заходит, так
// что подписка переживает удаление.
procedure RemovePreviousVersion();
var
  UninstallString: String;
  ResultCode: Integer;
begin
  // Ключ = AppId + "_is1". AppId прописан в [Setup] как {{8F3A...} — двойная
  // скобка там это экранирование, реальное значение с одной. Внутри Паскаля
  // подстановки констант нет, поэтому пишем как есть.
  if not RegQueryStringValue(HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3A9C21-4B7E-4D62-9E15-2A6C8D5F1B03}_is1',
      'UninstallString', UninstallString) then
    Exit;
  UninstallString := RemoveQuotes(UninstallString);
  if not FileExists(UninstallString) then
    Exit;
  WizardForm.StatusLabel.Caption := ExpandConstant('{cm:RemovingOld}');
  Exec(UninstallString, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1000);
end;

// Ядро без версии — тупик, из которого приложение само не выберется.
//
// Ядра ставятся только если их ещё нет (см. [Files]): приложение обновляет их
// само, и откатывать назад то, что оно подняло, нельзя. Но у самосборного
// sing-box версия печатается как `unknown`, а автообновление сравнивает
// ЧИСЛА и такое ядро не трогает вообще — навсегда. Плюс такие сборки обычно
// собраны без части возможностей: у пойманного экземпляра не было gVisor, и
// TUN-режим на стеках `gvisor` и `mixed` падал на старте.
//
// Поэтому: увидели ядро, которое не называет свою версию, — удаляем, и на
// его место встаёт официальная сборка из дистрибутива. Ядро с нормальной
// версией не трогаем, оно в состоянии обновиться самостоятельно.
procedure ReplaceUnversionedCore();
var
  CorePath, OutFile: String;
  // Именно AnsiString: LoadStringFromFile отдаёт байты как есть, а в
  // Unicode-версии Inno обычная String с ним не сходится по типу.
  Content: AnsiString;
  ResultCode: Integer;
begin
  CorePath := ExpandConstant('{app}\sing-box.exe');
  if not FileExists(CorePath) then Exit;
  OutFile := ExpandConstant('{tmp}\core_version.txt');
  if not Exec(ExpandConstant('{cmd}'), '/c ""' + CorePath + '" version > "' + OutFile + '" 2>&1"',
              '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then Exit;
  if not LoadStringFromFile(OutFile, Content) then Exit;
  if Pos('version unknown', Content) > 0 then
    DeleteFile(CorePath);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if IsAppRunning() then
  begin
    if MsgBox(ExpandConstant('{cm:AppRunningAsk}'), mbConfirmation, MB_YESNO) <> IDYES then
    begin
      Result := ExpandConstant('{cm:AppRunningManual}');
      Exit;
    end;
    if not AskAppToQuit() then
    begin
      Result := ExpandConstant('{cm:AppRunningManual}');
      Exit;
    end;
  end;
  RemovePreviousVersion();
  ReplaceUnversionedCore();
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  if IsAppRunning() then
  begin
    if MsgBox(ExpandConstant('{cm:AppRunningAsk}'), mbConfirmation, MB_YESNO) = IDYES then
      Result := AskAppToQuit()
    else
      Result := False;
    if not Result then
      MsgBox(ExpandConstant('{cm:AppRunningUninstall}'), mbError, MB_OK);
  end;
end;
