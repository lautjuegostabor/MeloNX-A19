# Estado de A19Core

El informe de investigación posterior revisa la elección de S2Arm del traspaso. El candidato de esta revisión reconstruye MeloNX v0.6 y mide el camino crítico de pipelines. El checkpoint nativo conserva su ruta de compilación y sus formatos. La observación de un juego que rindió peor en el emulador basado en S2Arm es cualitativa. Faltan título, escena, versiones, configuración y trazas comparables.

| Componente | Verificado en código | Probado en host Linux x86-64 | Compilado para iOS | Validado en iPhone 17 | Comparación controlada |
|---|---|---|---|---|---|
| MeloNX v0.6 de referencia | Fuente `f925129`, overlay SHA-256 fijado y cuatro parches de `1b9e58a` restaurados | Aplicación de los parches históricos | Build histórica según el traspaso | Juegos funcionales en el historial | Pendiente |
| Candidato v0.6 instrumentado | Parche acotado a métricas de preparación de programas, lock y creación Vulkan | Backend Vulkan Release, prueba C de JSONL con core simulado y 72 contadores, acumulación C# concurrente | [IPA ARM64 verificado](https://github.com/lautjuegostabor/MeloNX-A19/actions/runs/45621276570/artifacts/15024828336) | BOTW ejecutado y trazado. Cierre con fallo reportado | Pendiente |
| Candidato Apple10 de render | Creación de pipelines al primer uso y conservación de pases compatibles. Opciones independientes, apagadas por defecto, para iPhone 17 base con `MTLDevice.supportsFamily(.apple10)` | Backend Vulkan Release, etapas de shader, identidad de attachments y JSONL de 84 contadores | Pendiente | Pendiente | Pendiente |
| Checkpoint nativo `0100170` | Restauración con hashes desde S2Arm `39d35671` | Sintaxis de claves, extracción, IMG/USTAR, tabla de drivers y recuperación de paquete sintéticos | [IPA histórico](https://github.com/lautjuegostabor/MeloNX-A19/actions/runs/45578939713) | Flujo completo pendiente | Pendiente |
| Checkpoint nativo `1f6c660` y gate actualizado | Restauración con hashes y selección exacta del SDK | Pruebas anteriores, paridad Mach-O normal/FAR/biased-dual, ejecutable de fixtures NativeAOT y DFS diferencial | [Falló el CI histórico](https://github.com/lautjuegostabor/MeloNX-A19/actions/runs/45579611946). Gate actualizado probado en Linux | Pendiente | Pendiente |

## Reproducción

Ejecutar los comandos desde la rama de trabajo con el historial Git disponible y SDK .NET 10.0.402 para el host.

```sh
bash a19core/melonx/restore-v06.sh ../melonx-baseline
bash a19core/melonx/restore-v06.sh ../melonx-instrumented --instrument
python3 a19core/melonx/check-telemetry.py ../melonx-instrumented
dotnet build ../melonx-instrumented/src/Ryujinx.Graphics.Vulkan/Ryujinx.Graphics.Vulkan.csproj -c Release
```

El test ejecuta el escritor C real con un lector de contadores simulado y verifica nombres, orden, versión y muestras JSONL. El backend Vulkan compiló con dos advertencias CA2265 preexistentes en `DescriptorSetUpdater.cs`. Las pruebas del checkpoint usaron el gate de CI, incluido el script Python que produce los tres fixtures y `dotnet run --project a19-tests/ConverterTests.csproj -c Release` con reflexión JSON deshabilitada. La regresión C verificó que `spin_walk` coincide con la del reescritor y pasó 20.000 grafos diferenciales más 129 nodos con pila de 544 KiB bajo ASan y UBSan, con LeakSanitizer deshabilitado por la restricción de ptrace del sandbox.

También publiqué y ejecuté los mismos fixtures como binario NativeAOT Linux x86-64 con `dotnet publish a19-tests/ConverterTests.csproj -c Release -r linux-x64 -p:PublishAot=true -p:CppCompilerAndLinker=gcc`. Los cuatro grupos de pruebas pasaron. NuGet emitió NU1903 por `Microsoft.DotNet.ILCompiler` 10.0.13 durante esa publicación. Esta cobertura corresponde al ejecutable de pruebas del host. El framework NativeAOT de iOS y su enlace con el runtime nativo requieren una validación aparte. [Aviso de NuGet](https://github.com/advisories/GHSA-p3jp-9v83-76w9)

El job histórico instala 10.0.402 y termina con código 1 antes de generar fixtures. El log no muestra el SDK efectivo. El gate ajustado antepone `DOTNET_ROOT` al PATH, fija el SDK con `rollForward: disable` e imprime `dotnet --info`. El workflow v0.6 exige el gate de Linux antes del archivo de Xcode y publica procedencia y hash junto al IPA. El checkpoint nativo es despachable y conserva el disparo por cambios al delta. Los cambios de workflow por sí solos no disparan su compilación nativa.

## Interpretación de la captura

La versión 3 agrega cinco contadores acumulativos y preserva los índices históricos. El delta de `foreground_pipeline_create_calls` cuenta llamadas Vulkan de creación desde el camino síncrono de enlace a dibujo o dispatch. `foreground_pipeline_lock_ticks` abarca desde antes de entrar al lock hasta comenzar la llamada al driver. `foreground_pipeline_create_ticks` cubre la llamada, independientemente del resultado Vulkan. `foreground_program_ready_*` mide los intentos bloqueantes de preparación en ese camino, incluida la comprobación de disponibilidad y su trabajo síncrono. Dividir los ticks por `stopwatchFrequency`. Los contadores de creación global incluyen los de foreground, y el tiempo de preparación puede incluir trabajo de compilación. No sumar estas métricas como tiempo perdido por frame. Los contadores nuevos no registran el scanout ni reemplazan una medición de latencia física o de overhead.

Cuando exista un IPA validado por CI, la prueba física diagnóstica es una sola carga del juego reportado. Con la configuración efectiva de MeloNX estable y una condición térmica inicial comparable, iniciar la captura en A19 Lab, recorrer una escena con el problema y repetirla desde el mismo punto en esa sesión. Exportar el JSON y el JSONL al terminar. Efectos visuales, bloqueos y errores de arranque se registran como fallos. La captura sola no establece superioridad frente a MeloNX o S2Arm. El flujo nativo de conversión/importación/firma y el rendimiento sostenido siguen pendientes de validación en el dispositivo.


## Candidato Apple10 local

La ruta heredada prepara un pipeline con estado aproximado para un programa recién traducido, antes de conocer el estado con el que se emitirá el dibujo o dispatch. Con la opción **Apple10 pipelines on first use**, los programas de esa ruta preparan sus módulos y usan la creación existente de Vulkan al primer uso con estado real. Se conservan las rutas de programas recuperados del caché y las que usan compilación asíncrona. La modificación mantiene el lock de Vulkan, los formatos de shader y el orden de render. El nuevo contador `deferred_apple10_pipeline_warmups` comprueba cuántas veces se eligió esta ruta y es independiente de los tiempos de espera y de creación.

La captura de BOTW indica contención en el comienzo de la parte jugable. No cuantifica cuántas preparaciones anticipadas se reutilizaban. Si se reutilizaban con frecuencia, pasar a primer uso puede trasladar trabajo al dibujo. Los envíos Vulkan por fotograma se evalúan por separado. El cambio no introduce un backend Metal nativo ni demuestra una mejora sostenida.

```sh
bash a19core/melonx/restore-v06.sh ../melonx-apple10 --apple10
python3 a19core/melonx/check-telemetry.py ../melonx-apple10 --schema 5
dotnet run --project a19core/melonx/apple10-tests/Apple10.Tests.csproj -c Release -p:MeloNXSource="$(cd ../melonx-apple10 && pwd)"
```

El fixture maneja objetos `ShaderCollection` del backend real con módulos simulados. Comprueba el contrato de preparación de etapas sin ejecutar Vulkan, Metal o un juego. El IPA de la ejecución 45621276570 es la referencia de diagnóstico anterior.


**Apple10 reuse render pass** permite conservar el pase principal activo cuando se vuelven a configurar exactamente las mismas vistas vivas, en los mismos slots y con la misma vista de profundidad. Las actualizaciones de attachments filtradas por máscara conservan la ruta de recreación. Cuando cambian las vistas, se cierra el pase con el framebuffer anterior para registrar sus stores antes de cambiar los bindings. En la ruta reutilizada se vuelven a comprobar las barreras de los bindings antes del siguiente dibujo.

El esquema 5 agrega contadores de pases conservados y pases terminados, y clasifica las llamadas a `FlushCommandsImpl` por motivo. Son contadores de solicitudes de flush del pipeline principal. Una solicitud puede enviar varios buffers, y hay envíos que provienen de otros caminos. El contador histórico `queue_submit_calls` sigue midiendo las llamadas Vulkan. BOTW registró cerca de 23 envíos por fotograma incluso en el tramo final sin compilación de pipelines. Esa traza precede al desglose y no establece qué fracción de esos envíos evitaba conservar el framebuffer. El fixture comprueba coincidencia de vistas vivas, slots vacíos, cambios de orden, cambios de profundidad y descarte de vistas inválidas con la clase real `FramebufferParams`. El efecto visual y el rendimiento en Apple10 requieren verificación física.
