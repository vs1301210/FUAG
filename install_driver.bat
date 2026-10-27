@echo off
chcp 65001 > nul
echo ===================================================
echo     INSTALADOR DO DRIVER VIRTUAL (ViGEmBus)
echo ===================================================
echo.
echo Este driver permite que o Windows reconheça o celular
echo diretamente como um controle oficial de Xbox 360 ou PS4.
echo.
echo Solicitando permissão de Administrador...
powershell -Command "Start-Process msiexec.exe -ArgumentList '/i \"%~dp0tools\ViGEmBusSetup_x64.msi\" /passive /norestart' -Verb RunAs"
echo.
echo Concluído! Se a janela de permissão apareceu, confirme 'Sim'.
echo Pressione qualquer tecla para fechar...
pause > nul
