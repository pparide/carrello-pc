@echo off
rem Doppio clic: mostra cosa farebbe la configurazione, SENZA modificare nulla (risultato in Simulazione_NOMEPC.txt).
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%~dp0Installa-PC.ps1\" -Simula'"
