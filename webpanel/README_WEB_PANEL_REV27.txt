REV27.2 PERMISSION FIX
=======================
Corrige únicamente permisos de /etc/golden-web para que el servicio golden-web pueda leer config/TLS.

GOLDEN ADM PRO - WEB CONTROL CENTER V1 (REV27.2)
================================================

OBJETIVO
--------
Agregar un panel web moderno EXCLUSIVAMENTE al GENERADOR Golden ADM PRO.
No reemplaza el comando "gerar" ni modifica el motor estable REV26.3.

BASE ESTABLE CONSERVADA
-----------------------
- Golden System PRO REV26.3 (Hysteria Fix)
- /bin/gerar sigue funcionando por SSH.
- /etc/http-shell sigue siendo la única fuente de keys.
- /etc/SCRIPT sigue siendo la fuente de payloads.
- TCP 8888 sigue siendo el servidor de keys.
- Apache sigue en TCP 81.
- TCP 80 no se toca.
- Fast Bundle + SHA-256 no se toca.
- Protocolos de VPS clientes no se tocan.

PUERTO DEL PANEL
----------------
Por defecto: HTTPS TCP 8443.
El instalador RECHAZA 80, 81 y 8888 para evitar conflictos.
Puedes elegir otro puerto >=1024 si 8443 ya está ocupado.

ARQUITECTURA
------------
El panel y su puente administrativo son binarios Go estáticos, sin Node/PHP/Python.
Se incluyen:
- Linux AMD64/x86_64
- Linux ARM64/aarch64
- Linux x86/386

FUNCIONES WEB V1
----------------
1. Login obligatorio usuario + contraseña.
2. Contraseña almacenada con PBKDF2-HMAC-SHA256, salt aleatorio y 300,000 iteraciones.
3. Bloqueo temporal después de múltiples intentos incorrectos.
4. Sesiones Secure + HttpOnly + SameSite=Strict.
5. Protección CSRF para acciones de escritura.
6. HTTPS con certificado autofirmado inicial.
7. Dashboard:
   - Servidor ONLINE/OFF
   - IP pública
   - Puerto 8888
   - Instalaciones
   - Keys totales/activas/usadas/IP fija
   - CPU/RAM/disco/uptime
8. Crear key usando el MISMO comando /bin/gerar --create:
   - Instalación completa
   - Todas las herramientas adicionales
   - Selección individual de herramientas adicionales
   - IP fija opcional
9. Ver/buscar keys.
10. Borrar key individual.
11. Limpiar keys usadas.
12. Agregar/cambiar/quitar IP fija.
13. Iniciar/detener servidor de keys 8888.
14. Ver registro de accesos y servidor HTTP.
15. Cambiar message.txt.
16. Diagnóstico de sistema/puertos/Apache/servidor.
17. Ejecutar la MISMA actualización de Golden disponible en gerar opción [8].
18. Cambiar contraseña del panel.
19. Auditoría de login y acciones web.

ARQUITECTURA DE SEGURIDAD
-------------------------
El proceso web NO corre como root. Corre como usuario del sistema "golden-web".
Las acciones privilegiadas pasan únicamente por:
/usr/local/sbin/golden-web-bridge

El bridge es root-owned y acepta una lista cerrada de comandos; no ofrece una terminal
ni permite ejecutar comandos arbitrarios desde el navegador.

INSTALACIÓN LOCAL
-----------------
1. Copia/descomprime esta carpeta en la VPS DEL GENERADOR.
2. Entra como root.
3. Ejecuta:

   chmod +x instalar_webpanel.sh
   bash instalar_webpanel.sh

4. El instalador pedirá:
   - usuario web
   - contraseña web
   - puerto HTTPS (8443 por defecto)

5. Abre:

   https://IP-DE-LA-VPS:8443

El certificado inicial es autofirmado, así que el navegador puede mostrar una
advertencia la primera vez. La conexión sigue cifrada. Más adelante puedes usar
un dominio/certificado público si lo deseas.

INSTALACIÓN DESDE GITHUB
------------------------
Sube la carpeta "webpanel" del paquete GITHUB a:

satanas66666/golden-system2/webpanel/

Después, en la VPS del generador:

wget -qO instalar_webpanel_remoto.sh \
https://raw.githubusercontent.com/satanas66666/golden-system2/main/webpanel/instalar_webpanel_remoto.sh

chmod +x instalar_webpanel_remoto.sh
bash instalar_webpanel_remoto.sh

El instalador remoto detecta la arquitectura y descarga únicamente los 2 binarios
necesarios para esa VPS.

COMPROBACIONES DESPUÉS DE INSTALAR
----------------------------------
SSH tradicional debe seguir funcionando:

   gerar

Estado panel:

   systemctl status golden-web --no-pager

Health HTTPS:

   curl -k https://127.0.0.1:8443/api/health

Puertos:

   ss -lntp | grep -E ':80|:81|:8443|:8888'

Esperado:
- Panel: 8443
- Apache Golden: 81
- Keys: 8888
- 80: no es reservado por el panel

FIREWALL / PROVEEDOR
--------------------
El instalador NO cambia firewall para no afectar la estabilidad.
Si 8443 no abre desde Internet, permite TCP 8443 en el firewall/panel de tu VPS.

DESINSTALACIÓN
--------------

chmod +x desinstalar_webpanel.sh
bash desinstalar_webpanel.sh

Esto elimina SOLO el panel web. No borra gerar, keys, archivos, 8888 ni Apache.

IMPORTANTE - PRIMERA PRUEBA REAL
--------------------------------
Este V1 fue validado en laboratorio local (binarios, bridge, login HTTPS, sesiones,
CSRF, creación/lectura de keys simulada y acciones de filesystem). NO se afirma aún
que fue probado dentro de tu VPS real del generador. Primero instálalo como complemento,
prueba que gerar sigue intacto y después validamos las acciones una por una.

REGLA PARA SIGUIENTES REVISIONES
--------------------------------
Mientras el panel esté en prueba:
- NO integrar todavía el panel automáticamente dentro de goldengen.sh.
- NO modificar REV26.3 por errores del panel.
- Los arreglos del panel deben permanecer en la carpeta webpanel.
- Cuando quede validado en VPS real, se podrá agregar una opción opcional en gerar:
  "Administrar Panel Web" sin tocar el motor de keys.
