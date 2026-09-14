class ProductDeletionEvaluation {
  const ProductDeletionEvaluation({
    required this.openingMovementCount,
    required this.canUpdateOpening,
  });

  final int openingMovementCount;
  final bool canUpdateOpening;
}

abstract interface class ProductLifecycleGateway {
  Future<ProductDeletionEvaluation> evaluateDeletion(int productId);

  Future<void> deactivate(int productId);

  Future<void> deletePermanently(int productId);

  Future<void> reactivate(int productId);
}

class ProductLifecycleOfflineException implements Exception {
  const ProductLifecycleOfflineException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ProductLifecycleUseCase {
  const ProductLifecycleUseCase(this._gateway);

  final ProductLifecycleGateway _gateway;

  Future<ProductDeletionEvaluation> evaluateDeletion(int productId) {
    return _gateway.evaluateDeletion(productId);
  }

  Future<void> deactivate(int productId, {required bool offline}) {
    if (offline) {
      throw const ProductLifecycleOfflineException(
        'No puedes desactivar productos sin conexión.',
      );
    }
    return _gateway.deactivate(productId);
  }

  Future<void> deletePermanently(int productId, {required bool offline}) {
    if (offline) {
      throw const ProductLifecycleOfflineException(
        'No puedes eliminar definitivamente un producto sin conexión.',
      );
    }
    return _gateway.deletePermanently(productId);
  }

  Future<void> reactivate(int productId) => _gateway.reactivate(productId);
}
