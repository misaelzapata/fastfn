# Por que FastFN? Comparacion Tecnica

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por funcion desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

Comparar FastFN con alternativas ayuda a ubicar donde encaja mejor. FastFN cubre el hueco entre plataformas FaaS muy rigidas y frameworks web tradicionales.

## Resumen

| Feature | FastFN | FastAPI / Express | Nginx Unit | Next.js API Routes |
| :--- | :--- | :--- | :--- | :--- |
| **Routing** | File-System (intuitivo) | Codigo (`@app.get`) | API JSON (imperativo) | File-System |
| **Setup** | Zero config | Boilerplate | Llamadas a Config API | Zero config |
| **Experiencia** | "Drop code & run" | "Build app & run" | "Configure listener & apps" | "Drop code & run" |
| **Lenguajes** | Polyglot (mix and match) | Lenguaje unico | Polyglot | Solo JS/TS |
| **Hot Reload** | Inmediato (watcher) | Reinicio app | Recarga app | Inmediato |

## vs FastAPI / Express

FastAPI y Express son excelentes para servicios monoliticos.

**Problemas tipicos:**

- **Boilerplate**: setup manual de server, CORS, middleware y rutas.
- **Monolito**: con crecimiento, el archivo principal se vuelve grande o requiere mucha fragmentacion interna.
- **Lenguaje unico**: dificil mezclar Rust/Python/Node en una misma topologia HTTP simple.

**Enfoque FastFN:**

- **Zero boilerplate**: escribes el handler y listo.
- **Micro-funciones**: cada archivo es una unidad aislada.
- **Polyglot**: puedes resolver un endpoint puntual con otro runtime sin rehacer la app entera.

## vs Nginx Unit

Nginx Unit es un gran application server polyglot.

**Problemas tipicos:**

- **Complejidad de configuracion**: se opera via REST API con payloads JSON grandes.
- **No resuelve routing interno**: ejecuta apps, pero tu routing de negocio sigue dentro de cada framework.
- **DX local**: hot-reload y routing local suelen requerir scripts extra.

**Enfoque FastFN:**

- **Convencion sobre configuracion**: rutas desde file system.
- **Dev server pensado para DX**: `fastfn dev` observa cambios y recarga rapido.

## vs OpenFaaS / Knative

Son plataformas FaaS sobre Kubernetes.

**Problemas tipicos:**

- **Complejidad operativa**: Kubernetes, Helm, registry, build de imagenes.
- **Loop lento**: cambio -> build -> push -> deploy -> test.
- **Huella mayor**: cada funcion suele vivir en contenedor/pod dedicado.

**Enfoque FastFN:**

- **Local-first**: pensado para laptop/VPS con Docker o modo native.
- **Modelo de ejecucion**: workers pre-calentados, sin build por funcion.
- **Feedback rapido**: modo desarrollo en tiempo real.

## vs Next.js API Routes

Next.js popularizo una DX excelente con file-system routing.

**Problemas tipicos:**

- **JS/TS only**: acoplamiento al ecosistema Node.
- **Limites backend**: tareas pesadas o de sistema requieren mas cuidado.

**Enfoque FastFN:**

- **Misma DX, varios lenguajes**: routing por archivos aplicado a Node, Python, PHP, Rust y mas.
- **Aislamiento por funcion**: mejor control de fallas y limites por endpoint.

## Cuando usar FastFN

- prototipado rapido de APIs
- monorepos polyglot
- self-hosted FaaS con DX tipo Lambda/Vercel

## Guia de decision y migracion

Usa FastFN primero para endpoints HTTP stateless con ownership por archivo.

Secuencia de migracion:

1. mover endpoints stateless primero
2. mantener realtime/SSR en stack existente
3. extraer auth/validation a helpers compartidos
4. validar paridad con tests + OpenAPI

## Enlaces relacionados

- [Matriz de soporte protocolos avanzados](./matriz-soporte-protocolos-avanzados.md)
- [Arquitectura](./arquitectura.md)
- [Historia, diseno y futuro](./historia-diseno-futuro.md)
