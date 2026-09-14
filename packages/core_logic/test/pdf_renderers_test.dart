import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final documento = <String, dynamic>{
    'id': 42,
    'fecha': '2026-08-19T12:00:00-05:00',
    'total': 25.0,
    'validez_dias': 15,
  };
  final detalles = <Map<String, dynamic>>[
    {
      'cantidad': 2,
      'tipo_unidad': 'unidad',
      'precio_unitario': 12.5,
      'subtotal': 25.0,
      'productos': {'nombre': 'Producto prueba', 'codigo': 'P-001'},
    },
  ];
  final cliente = <String, dynamic>{
    'nombre': 'Cliente Prueba',
    'dni_ruc': '12345678',
    'direccion': 'Dirección de prueba',
  };
  final branding = PdfBranding(
    fiscalProfile: const BusinessFiscalProfile(
      businessId: '42',
      locationCode: '0000',
      taxIdentifier: '20123456789',
      legalName: 'EMPRESA PRUEBA SAC',
      tradeName: 'Tienda Prueba',
      address: FiscalAddress(
        street: 'Av. Prueba 123',
        locationCode: '0000',
        geoCode: '150101',
        countryCode: 'PE',
      ),
      phone: '999999999',
    ),
  );

  test('VentaTicketPdfRenderer genera un PDF válido', () async {
    final bytes = await VentaTicketPdfRenderer.generar(
      documento,
      detalles,
      cliente,
      null,
      branding: branding,
    );
    expect(bytes.length, greaterThan(100));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('CotizacionPdfRenderer genera un PDF válido', () async {
    final bytes = await CotizacionPdfRenderer.generar(
      documento,
      detalles,
      cliente,
      branding: branding,
    );
    expect(bytes.length, greaterThan(100));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
