/// The channel ceiling — which release channel may reach which stage — and where it is declared.
///
/// IT IS A SECURITY BOUNDARY AND NOT A CONVENIENCE. The channel is read from the release TAG, so the
/// tag is the truth rather than a parameter, and the ceiling decides what an `alpha` build may be
/// deployed to. It is enforced where something WRITES: the gate-stage task of every unit's release
/// Pipeline checks the requested stage against the table before any clone, and the bump task
/// re-checks it before every pin write.
///
/// ONE TABLE, READ BY EVERYONE. A second copy is not a duplicated constant, it is a second answer to
/// "may this reach prod" — and nothing says which of the two the next writer will consult. The build
/// plane takes it through the shared values chain
/// (apps/consumer-build/templates/pipeline-release.yaml serializes it for its shell at render time,
/// from `.Values.global.channelStages`), and the controller reads this very file over its config
/// route rather than carrying a copy.
library;

/// The one file the table is declared in.
const String channelTableFile = 'platform/values-common.yaml';

/// The key it stands under, in that file and in every reader's `.Values.global.` path.
const String channelTableKey = 'channelStages';

/// The pattern that finds the table stated as a mapping key of its own.
///
/// A KEY IS NOT A READING. `.Values.global.channelStages`, `$channelStages` and a sentence in a
/// comment all name the table without restating it, and all three stand in this tree today; none of
/// them can begin a line with the bare key, which is what this matches. What does match is the table
/// itself, wherever somebody writes it down a second time — in a values file, in a ConfigMap, or in
/// a heredoc inside a script block.
final RegExp channelTableStatement = RegExp('^[ \\t]*$channelTableKey[ \\t]*:');
