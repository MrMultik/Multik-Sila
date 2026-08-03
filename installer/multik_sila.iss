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
#define AppVersion "1.0.0"
#define AppExeName "proxy_app_test.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
; AppId менять НЕЛЬЗЯ: по нему Windows отличает обновление от новой установки.
; Другой AppId — и рядом появится вторая копия вместо обновления существующей.
AppId={{8F3A9C21-4B7E-4D62-9E15-2A6C8D5F1B03}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Multik Sila
DefaultDirName={autopf}\Multik Sila
DefaultGroupName=Multik Sila
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=MultikSila-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Ставим в Program Files, поэтому нужны права администратора. Само приложение
; при этом работает и без них — они требуются только TUN-режиму, и он
; запрашивает их отдельно, перезапуская приложение.
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
; Заявляем совместимость с Windows 10 и новее: TUN-адаптер и wintun на более
; старых системах не проверялись.
MinVersion=10.0

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Вся release-сборка целиком: exe, dll движка и плагинов, папка data и оба ядра.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

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
