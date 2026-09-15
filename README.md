# 🏗️ Ferretería App

Sistema integral de gestión comercial para ferreterías, desarrollado con Flutter y Supabase.

## 📋 Características Principales

### 🛒 Gestión de Ventas
- Cotizaciones y notas de venta
- Generación de PDFs automáticos
- Gestión de clientes y cuentas por cobrar
- Historial de transacciones

### 📦 Gestión de Inventario
- Control de stock en tiempo real
- Movimientos y kardex
- Alertas de bajo stock
- Gestión de múltiples almacenes
- Reportes de inventario

### 👥 Gestión de Empleados
- Control de nómina y pagos
- Historial de pagos
- Asignación de roles y permisos
- Perfil de usuario

### 📊 Reportes y Análisis
- Reportes de ventas y gastos
- Balance y caja chica
- Exportación a PDF y Excel
- Gráficos de tendencias
- Dashboard interactivo

### 💰 Gestión Financiera
- Registro de gastos
- Cuentas por pagar a proveedores
- Cierre de caja
- Balance general

## 🔐 Seguridad

- Autenticación con Supabase
- Control de roles (Admin, Vendedor, Empleado)
- Sincronización en tiempo real
- Soporte offline con LocalStorage

## 🛠️ Stack Tecnológico

- **Frontend**: Flutter 3.x
- **Backend**: Supabase (PostgreSQL)
- **State Management**: Riverpod
- **PDF Generation**: pdf package
- **Charts**: fl_chart
- **Data Export**: Excel package

## 📱 Plataformas Soportadas

- Android
- iOS
- Web
- Windows
- macOS
- Linux

## 🚀 Instalación

### Requisitos Previos
```bash
- Flutter SDK 3.x o superior
- Dart 3.x o superior
- Git
```

### Pasos de Instalación

1. Clonar el repositorio
```bash
git clone https://github.com/usuario/ferreteria_app.git
cd ferreteria_app
```

2. Instalar dependencias
```bash
flutter pub get
```

3. Configurar Supabase
- Crear proyecto en [supabase.com](https://supabase.com)
- Actualizar credenciales en `lib/main.dart`

4. Ejecutar la aplicación
```bash
flutter run
```

## 📝 Estructura del Proyecto

```
lib/
├── auth/                 # Autenticación y login
├── core/                 # Servicios y utilidades
│   ├── services/         # Supabase, PDF, Excel
│   ├── theme/            # Colores y estilos
│   └── utils/            # Helpers y formatos
├── features/             # Módulos funcionales
│   ├── almacen/          # Inventario
│   ├── balance/          # Caja y finanzas
│   ├── empleados/        # Gestión de personal
│   ├── ventas/           # Ventas y cotizaciones
│   ├── reportes/         # Reportes
│   ├── deudas/           # Cuentas por cobrar
│   └── kardex/           # Kardex de inventario
├── home/                 # Dashboard principal
├── splash/               # Pantalla de inicio
└── main.dart             # Punto de entrada
```

## 📚 Documentación

Ver carpeta `docs/` para:
- Arquitectura del proyecto
- Flujos de datos
- Guía de desarrollo
- Auditoría del código

## 🐛 Problemas Conocidos

- Sincronización con Supabase puede retrasar con conexión lenta
- Reportes grandes pueden tardar en generar

## 🤝 Contribuciones

1. Fork el proyecto
2. Crear rama de feature (`git checkout -b feature/AmazingFeature`)
3. Commit cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abrir Pull Request

## 📄 Licencia

Este proyecto está bajo la Licencia MIT - ver `LICENSE` para más detalles.

## 📧 Contacto

Luis Fernando Aguilar Chaponan
- Email: luisfernandoaguilarchaponan@gmail.com
- GitHub: [@usuario](https://github.com/usuario)

---

**Última actualización**: 2026-07-27
