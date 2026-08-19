import 'dart:io';
import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';

void main() {
  final Directory repo = Directory.current.parent;
  final String appset = File('${repo.path}/argocd/apps/applicationset.yaml').readAsStringSync();
  final RunsOnSelector selector = runsOnSelectorIn(appset);
  print('literals=${selector.literals} stampedRole=${selector.stampedRole}');

  final Directory programs = Directory('${installationRoot().path}/ansiwise/programs');
  final String branch = File('${programs.path}/deploy-branch.yaml').readAsStringSync();
  print('allowed=${allowedRolesIn(branch)}');

  final Map<String, String> runsOn = <String, String>{};
  for (final FileSystemEntity each in Directory('${repo.path}/apps').listSync()) {
    final File manifest = File('${each.path}/app.yaml');
    if (manifest.existsSync()) {
      final String? value = runsOnIn(manifest.readAsStringSync());
      if (value != null) runsOn['apps/${each.path.split(RegExp(r"[\/]")).last}/app.yaml'] = value;
    }
  }
  final Map<String, String> selected = <String, String>{};
  for (final FileSystemEntity each in Directory('${repo.path}/argocd/apps').listSync()) {
    if (each is File && each.path.endsWith('.yaml')) {
      for (final String role in selectedRolesIn(each.readAsStringSync())) {
        selected[each.path.split(RegExp(r"[\/]")).last] = role;
      }
    }
  }
  print('runsOn=${runsOn.length} selected=$selected');
  print(
    'findings=${auditClusterRoleValues(runsOn: runsOn, selectedRoles: selected, selector: selector, allowedRoles: allowedRolesIn(branch))}',
  );
}
