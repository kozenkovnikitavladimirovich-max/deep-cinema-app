; Установщик Deep Cinema для Windows (Inno Setup 6).
; Собирается в облаке: iscc /DAppVersion=0.2.N /DSourceDir=..\DeepCinema installer\deepcinema.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\DeepCinema"
#endif

[Setup]
AppId={{6E4B6C1D-5B7A-4C1E-9D2F-0DEEC1E7A001}
AppName=Deep Cinema
AppVersion={#AppVersion}
AppVerName=Deep Cinema {#AppVersion}
AppPublisher=Deep Cinema
DefaultDirName={localappdata}\Programs\Deep Cinema
DefaultGroupName=Deep Cinema
DisableProgramGroupPage=yes
DisableDirPage=no
DisableWelcomePage=no
UsePreviousAppDir=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
#ifdef Lite
; Лёгкое обновление: только сама программа, без торрент-движка, агрегатора и помощника.
OutputBaseFilename=DeepCinema-Update-{#AppVersion}
#else
OutputBaseFilename=DeepCinema-Setup-{#AppVersion}
#endif
SetupIconFile=..\tool\assets\app_icon.ico
UninstallDisplayIcon={app}\Deep Cinema.exe
UninstallDisplayName=Deep Cinema
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
WizardSizePercent=110
WizardImageFile=side-164.bmp,side-246.bmp,side-328.bmp,side-410.bmp
WizardSmallImageFile=small-55.bmp,small-83.bmp,small-110.bmp,small-138.bmp
#if VER >= 0x06060000
WizardStyle=modern dark
#else
WizardStyle=modern
#endif
#if VER >= 0x06070000
WizardBackImageFile=back.png
#endif

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
ru.Desktop=Ярлык на рабочем столе
ru.Run=Запустить Deep Cinema

[Messages]
ru.WelcomeLabel1=Добро пожаловать в Deep Cinema
ru.WelcomeLabel2=Личный онлайн-кинотеатр: фильмы и сериалы в один клик.%n%nВ комплекте всё нужное — торрент-движок и агрегатор раздач. Ничего отдельно устанавливать не придётся.
ru.FinishedHeadingLabel=Готово!
ru.ConfirmUninstall=Удалить Deep Cinema со всеми компонентами?%n%nВаши списки и настройки останутся — их можно стереть в самой программе (Настройки → Данные).
ru.UninstalledAll=Deep Cinema удалена с компьютера.
ru.InstallingLabel=Устанавливаю Deep Cinema. Это займёт около минуты — программа откроется сама.
ru.WizardInstalling=Обновление Deep Cinema

[Tasks]
Name: "desktopicon"; Description: "{cm:Desktop}"; GroupDescription: "Ярлыки:"

[Files]
#ifdef Lite
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "\jackett,\flaresolverr,\byparr,\torrserver.exe"; Flags: ignoreversion recursesubdirs createallsubdirs
#else
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif
; Картинка для окна удаления (в том же стиле, что и установщик).
Source: "side-246.bmp"; DestDir: "{app}\uninst"; DestName: "side.bmp"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Deep Cinema"; Filename: "{app}\Deep Cinema.exe"
Name: "{autodesktop}\Deep Cinema"; Filename: "{app}\Deep Cinema.exe"; Tasks: desktopicon

[Run]
; Обычная установка — галочка «Запустить» на последней странице.
Filename: "{app}\Deep Cinema.exe"; Description: "{cm:Run}"; Flags: nowait postinstall skipifsilent
; Обновление из приложения (тихая установка) — запускаем новую версию сами.
Filename: "{app}\Deep Cinema.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM torrserver.exe"; Flags: runhidden; RunOnceId: "KillTs"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM JackettConsole.exe"; Flags: runhidden; RunOnceId: "KillJackett"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM flaresolverr.exe"; Flags: runhidden; RunOnceId: "KillFlare"

[Code]
// Перед установкой закрыть фоновые службы приложения, иначе их файлы заняты.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM "Deep Cinema.exe"', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM torrserver.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM JackettConsole.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM flaresolverr.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Sleep(600);
  Result := '';
end;

// ── Удаление в стиле установщика ─────────────────────────────────────
// В «Приложениях» Windows удаление запускается с ключами /SILENT /DCUI: стандартный
// серый вопрос не показывается, вместо него — своё окно в оформлении установщика.

const
  UninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6E4B6C1D-5B7A-4C1E-9D2F-0DEEC1E7A001}_is1';
  ClrBg = $1E1A1A;
  ClrText = $FFFFFF;
  ClrMuted = $A8A0A0;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Cmd: String;
begin
  if CurStep = ssPostInstall then begin
    Cmd := '"' + ExpandConstant('{uninstallexe}') + '" /SILENT /DCUI';
    RegWriteStringValue(HKA, UninstKey, 'UninstallString', Cmd);
  end;
end;

function HasDcUi: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/DCUI') = 0 then Result := True;
end;

function StyledBox(const Title, Text, OkText, CancelText: String): Boolean;
var
  Form: TSetupForm;
  Img: TBitmapImage;
  Head, Body: TNewStaticText;
  Ok, Cancel: TNewButton;
  Pic: String;
  Left: Integer;
begin
#if VER >= 0x06060000
  Form := CreateCustomForm(ScaleX(620), ScaleY(340), False, False);
#else
  Form := CreateCustomForm;
  Form.ClientWidth := ScaleX(620);
  Form.ClientHeight := ScaleY(340);
#endif
  try
    Form.Caption := 'Deep Cinema';
    Form.Color := ClrBg;
    Form.Position := poScreenCenter;
    Left := ScaleX(28);
    Pic := ExpandConstant('{app}\uninst\side.bmp');
    if FileExists(Pic) then begin
      Img := TBitmapImage.Create(Form);
      Img.Parent := Form;
      Img.Left := 0;
      Img.Top := 0;
      Img.Bitmap.LoadFromFile(Pic);
      // Ширина по пропорциям картинки — без сплющивания.
      Img.Height := Form.ClientHeight;
      Img.Width := Form.ClientHeight * Img.Bitmap.Width div Img.Bitmap.Height;
      Img.Stretch := True;
      Left := Img.Width + ScaleX(28);
    end;

    Head := TNewStaticText.Create(Form);
    Head.Parent := Form;
    Head.Left := Left;
    Head.Top := ScaleY(36);
    Head.Caption := Title;
    Head.Font.Size := 16;
    Head.Font.Style := [fsBold];
    Head.Font.Color := ClrText;

    Body := TNewStaticText.Create(Form);
    Body.Parent := Form;
    Body.Left := Left;
    Body.Top := ScaleY(84);
    Body.Width := Form.ClientWidth - Left - ScaleX(28);
    Body.AutoSize := False;
    Body.WordWrap := True;
    Body.Height := ScaleY(150);
    Body.Caption := Text;
    Body.Font.Size := 10;
    Body.Font.Color := ClrMuted;

    Ok := TNewButton.Create(Form);
    Ok.Parent := Form;
    Ok.Width := ScaleX(120);
    Ok.Height := ScaleY(32);
    Ok.Caption := OkText;
    Ok.ModalResult := mrOk;
    Ok.Default := True;

    if CancelText <> '' then begin
      Cancel := TNewButton.Create(Form);
      Cancel.Parent := Form;
      Cancel.Width := ScaleX(110);
      Cancel.Height := ScaleY(32);
      Cancel.Caption := CancelText;
      Cancel.ModalResult := mrCancel;
      Cancel.Cancel := True;
      Cancel.Left := Form.ClientWidth - ScaleX(24) - Cancel.Width;
      Cancel.Top := Form.ClientHeight - ScaleY(24) - Cancel.Height;
      Ok.Left := Cancel.Left - ScaleX(10) - Ok.Width;
    end else
      Ok.Left := Form.ClientWidth - ScaleX(24) - Ok.Width;
    Ok.Top := Form.ClientHeight - ScaleY(24) - Ok.Height;

    Form.ActiveControl := Ok;
    Result := Form.ShowModal = mrOk;
  finally
    Form.Free;
  end;
end;

function InitializeUninstall: Boolean;
begin
  Result := True;
  if HasDcUi then
    Result := StyledBox('Удалить Deep Cinema?',
      'Программа будет удалена вместе со встроенными компонентами — торрент-движком и агрегатором раздач.' + #13#10 + #13#10 +
      'Ваши списки, история и настройки останутся на компьютере. Стереть их можно в самой программе: Настройки → Данные.',
      'Удалить', 'Отмена');
end;

procedure InitializeUninstallProgressForm;
begin
  UninstallProgressForm.PageNameLabel.Caption := 'Удаление Deep Cinema';
  UninstallProgressForm.PageDescriptionLabel.Caption := 'Подождите несколько секунд…';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCodeDummy: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM "Deep Cinema.exe"', '', SW_HIDE, ewWaitUntilTerminated, ResultCodeDummy);
  end;
  if (CurUninstallStep = usPostUninstall) and HasDcUi then
    StyledBox('Готово', 'Deep Cinema удалена с компьютера. Спасибо, что смотрели с нами!', 'Закрыть', '');
end;
