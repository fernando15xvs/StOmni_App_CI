-- Fase 2A: índices de integridad referencial por tenant y venta.
-- No cambia escritores, saldos ni contratos de acceso.
CREATE INDEX IF NOT EXISTS venta_cronos_origen_evento_fin2a_idx
 ON public.venta_cronogramas(organization_id,venta_id,origen_evento_id);
CREATE INDEX IF NOT EXISTS venta_cuota_mov_cuota_fin2a_fk_idx
 ON public.venta_cuota_movimientos(organization_id,venta_id,cuota_id);
CREATE INDEX IF NOT EXISTS venta_cuota_mov_evento_fin2a_fk_idx
 ON public.venta_cuota_movimientos(organization_id,venta_id,evento_id);
CREATE INDEX IF NOT EXISTS venta_cuota_mov_reversa_fin2a_fk_idx
 ON public.venta_cuota_movimientos(organization_id,venta_id,reversa_movimiento_id);
CREATE INDEX IF NOT EXISTS venta_cuotas_crono_fin2a_fk_idx
 ON public.venta_cuotas(organization_id,venta_id,cronograma_id);
CREATE INDEX IF NOT EXISTS venta_eventos_nc_fin2a_fk_idx
 ON public.venta_eventos_financieros(organization_id,venta_id,nota_credito_id);
CREATE INDEX IF NOT EXISTS venta_eventos_op_fin2a_fk_idx
 ON public.venta_eventos_financieros(organization_id,venta_id,operacion_id);
CREATE INDEX IF NOT EXISTS venta_eventos_pago_fin2a_fk_idx
 ON public.venta_eventos_financieros(organization_id,venta_id,pago_id);
CREATE INDEX IF NOT EXISTS venta_eventos_reversa_fin2a_fk_idx
 ON public.venta_eventos_financieros(organization_id,venta_id,reversa_evento_id);
