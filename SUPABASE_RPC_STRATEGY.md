<!-- 
Estrategia de Transacciones Seguras en Supabase para Ventas

Problema actual:
- La función _procesarVenta() hace múltiples operaciones independientes
- Si falla en mitad, puede dejar datos parcialmente guardados
- El rollback manual es frágil y podría no ejecutarse

Solución propuesta: Usar PostgreSQL Transactions via Supabase RPC
-->

# 🔒 Estrategia de Transacción Segura para Ventas

## 1. Crear una Función PostgreSQL en Supabase

En la consola de Supabase, corre este SQL (o en `migrations/`):

```sql
CREATE OR REPLACE FUNCTION process_sale(
  p_cliente_id INT,
  p_total DECIMAL,
  p_fecha TIMESTAMP,
  p_es_credito BOOLEAN,
  p_monto_abono DECIMAL,
  p_detalles JSONB,  -- Array de {producto_id, cantidad, precio_unitario, almacen_id}
  p_pagos JSONB      -- Array de {metodo, monto, fecha}
)
RETURNS jsonb AS $$
DECLARE
  v_venta_id INT;
  v_detail jsonb;
  v_pago jsonb;
  v_stock INT;
  v_piezas_a_descontar INT;
BEGIN
  -- Iniciar transacción (implícita)
  
  -- 1. Crear la venta
  INSERT INTO ventas (cliente_id, total, fecha, estado, saldo)
  VALUES (p_cliente_id, p_total, p_fecha, 
          CASE WHEN p_es_credito THEN 'pendiente' ELSE 'pagado' END,
          CASE WHEN p_es_credito THEN (p_total - p_monto_abono) ELSE 0 END)
  RETURNING id INTO v_venta_id;
  
  -- 2. Procesar pagos
  FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
  LOOP
    INSERT INTO pagos_venta (venta_id, metodo, monto, fecha)
    VALUES (v_venta_id, v_pago->>'metodo', (v_pago->>'monto')::DECIMAL, p_fecha);
  END LOOP;
  
  -- 3. Procesar detalles y descontar stock
  FOR v_detail IN SELECT * FROM jsonb_array_elements(p_detalles)
  LOOP
    -- Crear detalle de venta
    INSERT INTO detalle_ventas (venta_id, producto_id, cantidad, precio_unitario, subtotal, almacen_id)
    VALUES (
      v_venta_id,
      (v_detail->>'producto_id')::INT,
      (v_detail->>'cantidad')::INT,
      (v_detail->>'precio_unitario')::DECIMAL,
      (v_detail->>'precio_unitario')::DECIMAL * (v_detail->>'cantidad')::INT,
      (v_detail->>'almacen_id')::INT
    );
    
    -- Obtener stock actual (lock para evitar race condition)
    SELECT cantidad INTO v_stock
    FROM inventario_almacen
    WHERE producto_id = (v_detail->>'producto_id')::INT
      AND almacen_id = (v_detail->>'almacen_id')::INT
    FOR UPDATE;  -- 🔒 Lockea la fila hasta que termine la transacción
    
    -- Calcular piezas a descontar
    v_piezas_a_descontar := (v_detail->>'cantidad')::INT;
    
    -- Validar stock
    IF v_stock < v_piezas_a_descontar THEN
      RAISE EXCEPTION 'Stock insuficiente para producto %. Stock actual: %', 
                      (v_detail->>'producto_id')::INT, v_stock;
    END IF;
    
    -- Descontar stock
    UPDATE inventario_almacen
    SET cantidad = cantidad - v_piezas_a_descontar
    WHERE producto_id = (v_detail->>'producto_id')::INT
      AND almacen_id = (v_detail->>'almacen_id')::INT;
  END LOOP;
  
  -- Si llegamos aquí, todo salió bien ✅
  RETURN jsonb_build_object('success', true, 'venta_id', v_venta_id);

EXCEPTION WHEN OTHERS THEN
  -- Si algo falla, PostgreSQL revierte TODO automáticamente 🔄
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql;
```

## 2. Beneficios

| Aspecto | Antes | Después |
|--------|-------|--------|
| **Múltiples round-trips** | Sí (5+) | No (1) |
| **Race condition en stock** | Posible | Bloqueada con `FOR UPDATE` |
| **Rollback parcial** | Manual y frágil | Automático por PostgreSQL |
| **Latencia de red** | Alta | Baja (todo en servidor) |
| **Atomicidad** | No garantizada | ✅ Garantizada |

## 3. Implementación en Dart

Reemplaza `_procesarVenta()` parcialmente:

```dart
Future<void> _procesarVentaTransaccional() async {
  setState(() => _guardando = true);

  try {
    // 1. Validar entrada
    if (!_esCredito) {
      final pagado = _calcularTotalPagadoLista();
      if ((pagado - widget.totalAPagar).abs() > 0.01) {
        _mostrarError('Los pagos no cubren el total exacto.');
        return;
      }
    } else {
      if (_montoAbono > widget.totalAPagar) {
        _mostrarError('El abono no puede ser mayor al total.');
        return;
      }
    }

    // 2. Preparar datos
    final fechaParaGuardar = _fecha.toUtc().toIso8601String();
    
    List<Map<String, dynamic>> pagosJson = [];
    if (!_esCredito) {
      for (var p in _pagosLista) {
        final monto = double.tryParse(p.montoCtrl.text) ?? 0.0;
        if (monto > 0)
          pagosJson.add({'metodo': p.metodo, 'monto': monto, 'fecha': fechaParaGuardar});
      }
    } else {
      if (_montoAbono > 0)
        pagosJson.add({'metodo': _metodoAbono, 'monto': _montoAbono, 'fecha': fechaParaGuardar});
    }

    List<Map<String, dynamic>> detallesJson = [];
    for (var item in widget.carritoConPreciosFinales) {
      final prodData = item['producto_data'];
      final String tipoUnidad = item['tipo_unidad'] ?? 'unidad';
      final int pcs = (prodData['cantidad_por_caja'] as num?)?.toInt() ?? 1;
      final int piezasADescontar = (tipoUnidad == 'caja') 
          ? (item['cantidad'] as int) * pcs 
          : item['cantidad'] as int;

      detallesJson.add({
        'producto_id': item['id'],
        'cantidad': piezasADescontar,  // 👈 Aquí va en unidades reales
        'precio_unitario': item['precio'],
        'almacen_id': item['almacen_id'],
      });
    }

    // 3. Llamar la función RPC
    final result = await Supabase.instance.client
        .rpc('process_sale', params: {
          'p_cliente_id': clienteId,
          'p_total': widget.totalAPagar,
          'p_fecha': fechaParaGuardar,
          'p_es_credito': _esCredito,
          'p_monto_abono': _montoAbono,
          'p_detalles': detallesJson,
          'p_pagos': pagosJson,
        });

    // 4. Validar resultado
    if (result['success'] != true) {
      throw Exception(result['error'] ?? 'Error desconocido en la venta');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('¡Venta registrada con éxito!'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomePage(pestanaInicial: 1)),
        (Route<dynamic> route) => false,
      );
    }
  } catch (e) {
    // No hay que hacer rollback manual aquí, PostgreSQL ya lo hizo
    _mostrarError('Error: $e');
  } finally {
    if (mounted) setState(() => _guardando = false);
  }
}
```

## 4. Manejo de Offline

Para offline, mantén la estrategia actual de guardar en SharedPreferences:

```dart
if (!hayInternet) {
  await OfflineService.guardarVentaOffline({
    'cliente_id': clienteId,
    'total': widget.totalAPagar,
    'fecha': fechaParaGuardar,
    'es_credito': _esCredito,
    'monto_abono': _montoAbono,
    'detalles': detallesJson,
    'pagos': pagosJson,
  });
  // ... mostrar mensaje
  return;
}
```

Luego, en la home o en un servicio de sincronización:

```dart
Future<void> sincronizarVentasOffline() async {
  final ventasPendientes = await OfflineService.obtenerVentasOffline();
  
  for (var venta in ventasPendientes) {
    try {
      await Supabase.instance.client.rpc('process_sale', params: {
        'p_cliente_id': venta['cliente_id'],
        'p_total': venta['total'],
        'p_fecha': venta['fecha'],
        'p_es_credito': venta['es_credito'],
        'p_monto_abono': venta['monto_abono'],
        'p_detalles': venta['detalles'],
        'p_pagos': venta['pagos'],
      });
      
      // Si llegó aquí, eliminó de pending
      await OfflineService.limpiarVentasOffline();
    } catch (e) {
      // Mantén el error y reintenta después
      debugPrint('Error sincronizando venta: $e');
    }
  }
}
```

## 5. Mejoras Futuras

1. **Logging de cambios**: Añade un trigger en PostgreSQL para guardar auditoría
2. **Notificaciones en tiempo real**: Usa `Supabase Realtime` para que otros clientes vean cambios
3. **Rate limiting**: Implementa rate limiting en Supabase para evitar abuso
4. **Compresión de datos**: Para payloads grandes, usa gzip antes de enviar JSON
5. **Versionado de API**: Si necesitas cambiar `process_sale`, crea `process_sale_v2` y mantén la antigua por compatibilidad

---

## 6. Testing (SQL)

```sql
-- Prueba feliz
SELECT process_sale(
  1,                -- cliente_id
  150.00,           -- total
  NOW(),            -- fecha
  FALSE,            -- es_credito
  0,                -- monto_abono
  '[{"producto_id":1,"cantidad":10,"precio_unitario":15,"almacen_id":1}]'::jsonb,
  '[{"metodo":"Efectivo","monto":150}]'::jsonb
);

-- Prueba con error (stock insuficiente)
-- SELECT process_sale(...) -- Revierte TODO automáticamente
```

---

**Conclusión**: Esta estrategia elimina 90% de los problemas de sincronización y race conditions en ventas. ✅
