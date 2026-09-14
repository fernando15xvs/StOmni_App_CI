import 'package:core_logic/onboarding/domain/guided_onboarding.dart';
import 'package:core_logic/onboarding/providers/guided_onboarding_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class GuidedOnboardingPage extends ConsumerStatefulWidget {
  const GuidedOnboardingPage({
    super.key,
    required this.initialProgress,
    required this.onCompleted,
  });

  final GuidedOnboardingProgress initialProgress;
  final VoidCallback onCompleted;

  @override
  ConsumerState<GuidedOnboardingPage> createState()=>_GuidedOnboardingPageState();
}

class _GuidedOnboardingPageState extends ConsumerState<GuidedOnboardingPage>{
  late GuidedOnboardingProgress _progress;
  bool _saving=false;
  String? _error;

  @override
  void initState(){
    super.initState();
    _progress=widget.initialProgress;
  }

  Future<void> _continue() async {
    if(_saving || _progress.completed) return;
    setState((){_saving=true;_error=null;});
    try{
      final next=await ref.read(guidedOnboardingUseCaseProvider).completeCurrentStep(_progress);
      if(!mounted) return;
      setState(()=>_progress=next);
      if(next.completed){
        ref.invalidate(guidedOnboardingProgressProvider);
        widget.onCompleted();
      }
    }catch(error){
      if(!mounted) return;
      setState(()=>_error=error.toString());
    }finally{
      if(mounted) setState(()=>_saving=false);
    }
  }

  @override
  Widget build(BuildContext context){
    final step=_progress.nextStep;
    final theme=Theme.of(context);
    return Scaffold(
      body:SafeArea(
        child:LayoutBuilder(
          builder:(context,constraints){
            final wide=constraints.maxWidth>=820;
            return Center(
              child:SingleChildScrollView(
                padding:const EdgeInsets.all(24),
                child:ConstrainedBox(
                  constraints:const BoxConstraints(maxWidth:980),
                  child:wide
                    ? Row(
                        crossAxisAlignment:CrossAxisAlignment.start,
                        children:[
                          SizedBox(width:280,child:_progressRail(theme)),
                          const SizedBox(width:28),
                          Expanded(child:_stepCard(theme,step)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment:CrossAxisAlignment.stretch,
                        children:[
                          _progressRail(theme),
                          const SizedBox(height:20),
                          _stepCard(theme,step),
                        ],
                      ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _progressRail(ThemeData theme)=>Card(
    child:Padding(
      padding:const EdgeInsets.all(22),
      child:Column(
        crossAxisAlignment:CrossAxisAlignment.start,
        children:[
          Text('Configura StOmni',style:theme.textTheme.titleLarge?.copyWith(fontWeight:FontWeight.w800)),
          const SizedBox(height:8),
          const Text('Confirma la base de tu empresa antes de comenzar a operar.'),
          const SizedBox(height:20),
          for(final item in GuidedOnboardingStep.values)
            _stepIndicator(theme,item),
        ],
      ),
    ),
  );

  Widget _stepIndicator(ThemeData theme,GuidedOnboardingStep step){
    final done=_progress.completedSteps.contains(step);
    final current=_progress.nextStep==step;
    return Padding(
      padding:const EdgeInsets.symmetric(vertical:7),
      child:Row(
        children:[
          Icon(done ? Icons.check_circle : current ? Icons.radio_button_checked : Icons.radio_button_off,
            color:done||current ? theme.colorScheme.primary : theme.disabledColor),
          const SizedBox(width:10),
          Expanded(child:Text(_title(step),style:TextStyle(fontWeight:current ? FontWeight.w700 : FontWeight.w500))),
        ],
      ),
    );
  }

  Widget _stepCard(ThemeData theme,GuidedOnboardingStep? step)=>Card(
    child:Padding(
      padding:const EdgeInsets.all(28),
      child:Column(
        crossAxisAlignment:CrossAxisAlignment.start,
        children:[
          Icon(_icon(step),size:46,color:theme.colorScheme.primary),
          const SizedBox(height:18),
          Text(step==null ? 'Configuración completa' : _title(step),style:theme.textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.w800)),
          const SizedBox(height:12),
          Text(_description(step),style:theme.textTheme.bodyLarge),
          const SizedBox(height:20),
          _verificationBox(theme,step),
          if(_error!=null)...[
            const SizedBox(height:18),
            Text(_error!,style:TextStyle(color:theme.colorScheme.error)),
          ],
          const SizedBox(height:28),
          Align(
            alignment:Alignment.centerRight,
            child:FilledButton.icon(
              onPressed:_saving||step==null ? null : _continue,
              icon:_saving
                ? const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2))
                : const Icon(Icons.arrow_forward),
              label:Text(step==GuidedOnboardingStep.review ? 'Finalizar configuración' : 'Confirmar y continuar'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _verificationBox(ThemeData theme,GuidedOnboardingStep? step)=>Container(
    width:double.infinity,
    padding:const EdgeInsets.all(16),
    decoration:BoxDecoration(
      color:theme.colorScheme.surfaceContainerHighest,
      borderRadius:BorderRadius.circular(12),
    ),
    child:Row(
      crossAxisAlignment:CrossAxisAlignment.start,
      children:[
        const Icon(Icons.verified_user_outlined),
        const SizedBox(width:12),
        Expanded(child:Text(_verification(step))),
      ],
    ),
  );

  String _title(GuidedOnboardingStep step)=>switch(step){
    GuidedOnboardingStep.businessProfile=>'Perfil del negocio',
    GuidedOnboardingStep.modules=>'Módulos y capacidades',
    GuidedOnboardingStep.operations=>'Operación inicial',
    GuidedOnboardingStep.review=>'Revisión final',
  };

  String _description(GuidedOnboardingStep? step)=>switch(step){
    GuidedOnboardingStep.businessProfile=>'StOmni verificará que tu empresa tenga una configuración empresarial creada antes de continuar.',
    GuidedOnboardingStep.modules=>'Confirma la configuración base de módulos. Podrás ajustar capacidades posteriormente desde la administración del negocio.',
    GuidedOnboardingStep.operations=>'Verifica que exista una sucursal principal y una caja predeterminada activas para comenzar a operar.',
    GuidedOnboardingStep.review=>'Revisa que los pasos anteriores estén completos. Al finalizar entrarás al espacio de trabajo de tu empresa.',
    null=>'Tu empresa ya está lista para usar StOmni.',
  };

  String _verification(GuidedOnboardingStep? step)=>switch(step){
    GuidedOnboardingStep.businessProfile=>'El servidor valida la existencia de configuracion_negocio para tu organización.',
    GuidedOnboardingStep.modules=>'El servidor valida business_capabilities del tenant; esta pantalla no inventa ni duplica esa configuración.',
    GuidedOnboardingStep.operations=>'El servidor exige sucursal principal activa y caja predeterminada activa.',
    GuidedOnboardingStep.review=>'El servidor sólo permite cerrar el onboarding si los tres pasos anteriores ya fueron reconocidos en orden.',
    null=>'Onboarding completado.',
  };

  IconData _icon(GuidedOnboardingStep? step)=>switch(step){
    GuidedOnboardingStep.businessProfile=>Icons.storefront_outlined,
    GuidedOnboardingStep.modules=>Icons.dashboard_customize_outlined,
    GuidedOnboardingStep.operations=>Icons.point_of_sale_outlined,
    GuidedOnboardingStep.review=>Icons.fact_check_outlined,
    null=>Icons.check_circle_outline,
  };
}
