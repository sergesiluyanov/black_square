import 'package:black_square/models/chat.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _nameController = TextEditingController();
  final _recipientIdController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _recipientIdController.dispose();
    super.dispose();
  }

  Future<void> _createChat() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final recipientId = _recipientIdController.text.trim();
    if (recipientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Отсканируйте QR-код собеседника или введите ID'),
          backgroundColor: Color(0xFF333333),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final chat = await context.read<ChatService>().createChat(name, recipientId: recipientId);
      if (mounted) Navigator.pop(context, chat);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onScanned(String id) {
    if (id.isNotEmpty) {
      _recipientIdController.text = id;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ID получен. Введите имя и нажмите «Создать чат»'),
          backgroundColor: Color(0xFF1A5F1A),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Новый чат',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ваш ID — покажите QR собеседнику:',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: context.read<ChatService>().userId,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'или скопируйте: ${context.read<ChatService>().userId}',
              style: const TextStyle(color: Color(0xFF6B8AFF), fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (ctx) => _QrScanScreen(onScanned: _onScanned),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF6B8AFF)),
              label: const Text(
                'Сканировать QR собеседника',
                style: TextStyle(color: Color(0xFF6B8AFF)),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: Color(0xFF6B8AFF)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                labelText: 'Имя контакта',
                labelStyle: const TextStyle(color: Colors.white54),
                hintText: 'Введите имя',
                hintStyle: const TextStyle(color: Colors.white24),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF333333)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF6B8AFF), width: 2),
                ),
              ),
              onSubmitted: (_) => _createChat(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _recipientIdController,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                labelText: 'ID пользователя (или отсканируйте)',
                labelStyle: const TextStyle(color: Colors.white54),
                hintText: 'UUID собеседника',
                hintStyle: const TextStyle(color: Colors.white24),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF333333)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF6B8AFF), width: 2),
                ),
              ),
              onSubmitted: (_) => _createChat(),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _isLoading ? null : _createChat,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6B8AFF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Создать чат'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrScanScreen extends StatefulWidget {
  final void Function(String id) onScanned;

  const _QrScanScreen({required this.onScanned});

  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  bool _scanned = false;
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.isNotEmpty) {
        _scanned = true;
        widget.onScanned(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Сканировать QR', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _onDetect,
            controller: _controller,
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white54, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 40),
            alignment: Alignment.bottomCenter,
            child: Text(
              'Наведите камеру на QR-код собеседника',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
