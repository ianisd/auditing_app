import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/logger_service.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  @override
  Widget build(BuildContext context) {
    final logger = context.read<LoggerService>();
    final logs = logger.getLogs();

    return Scaffold(
      appBar: AppBar(
        title: const Text('System Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy to Clipboard',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: logs.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs copied')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: () async {
              await logger.clearLogs();
              setState(() {});
            },
          ),
        ],
      ),
      body: Container(
        color: Colors.black,
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: logs.length,
          itemBuilder: (context, index) {
            final log = logs[index];
            final isError = log.contains('ERROR');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.0),
              child: Text(
                log,
                style: TextStyle(
                  color: isError ? Colors.redAccent : Colors.greenAccent,
                  fontFamily: 'Monospace',
                  fontSize: 12,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}