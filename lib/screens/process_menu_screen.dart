import 'package:flutter/material.dart';

class ProcessAction {
  final String title;
  final String description;
  final IconData icon;
  final WidgetBuilder builder;

  const ProcessAction({
    required this.title,
    required this.description,
    required this.icon,
    required this.builder,
  });
}

class ProcessMenu {
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final List<ProcessAction> actions;

  const ProcessMenu({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.actions,
  });
}

/// Shared menu for each home tile. Existing feature screens keep their own routes.
class ProcessMenuScreen extends StatelessWidget {
  final ProcessMenu menu;

  const ProcessMenuScreen({super.key, required this.menu});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(menu.title)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(menu.description,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 20),
                for (final action in menu.actions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        leading: Icon(action.icon, color: menu.color, size: 28),
                        title: Text(action.title),
                        subtitle: Text(action.description),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: action.builder),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
