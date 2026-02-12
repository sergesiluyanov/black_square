import 'package:black_square/services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
          content: Text('Введите ID пользователя для облачного чата'),
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
              'Ваш ID (поделитесь с собеседником):',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                context.read<ChatService>().userId,
                style: const TextStyle(color: Color(0xFF6B8AFF), fontSize: 12, fontFamily: 'monospace'),
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
                labelText: 'ID пользователя *',
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
