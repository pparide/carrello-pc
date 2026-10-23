@echo off
rem Doppio clic: configura questo PC per il carrello. Chiede solo il numero del carrello e del PC.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%~dp0Installa-PC.ps1\"'"
