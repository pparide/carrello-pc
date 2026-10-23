@echo off
rem Doppio clic: toglie blocchi, attivita pianificata e accesso automatico (non cancella account ne file).
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%~dp0Installa-PC.ps1\" -Annulla'"
