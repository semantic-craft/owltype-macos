#include <rime_api.h>

#include <stdio.h>

static const char* kModules[] = {"default", "plugins", nullptr};

int main(int argc, char* argv[]) {
  if (argc != 5) {
    fprintf(stderr, "usage: %s <shared_data_dir> <user_data_dir> <schema_id> <keys>\n", argv[0]);
    return 2;
  }

  const char* shared_data_dir = argv[1];
  const char* user_data_dir = argv[2];
  const char* schema_id = argv[3];
  const char* keys = argv[4];

  char prebuilt_data_dir[4096];
  char staging_dir[4096];
  snprintf(prebuilt_data_dir, sizeof(prebuilt_data_dir), "%s/build", shared_data_dir);
  snprintf(staging_dir, sizeof(staging_dir), "%s/build", user_data_dir);

  RimeApi* rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared_data_dir;
  traits.user_data_dir = user_data_dir;
  traits.prebuilt_data_dir = prebuilt_data_dir;
  traits.staging_dir = staging_dir;
  traits.distribution_name = "法墨输入法";
  traits.distribution_code_name = "Famo";
  traits.distribution_version = "probe";
  traits.app_name = "rime.famo-probe";
  traits.modules = kModules;
  traits.min_log_level = 2;
  traits.log_dir = "";

  rime->setup(&traits);
  rime->initialize(&traits);
  if (rime->start_maintenance(True)) {
    rime->join_maintenance_thread();
  }

  RimeSessionId session = rime->create_session();
  if (!session) {
    fprintf(stderr, "failed to create Rime session\n");
    rime->finalize();
    return 1;
  }

  if (!rime->select_schema(session, schema_id)) {
    fprintf(stderr, "failed to select schema: %s\n", schema_id);
  }
  if (!rime->simulate_key_sequence(session, keys)) {
    fprintf(stderr, "failed to process key sequence: %s\n", keys);
  }

  const char* commit_text = "";
  RIME_STRUCT(RimeCommit, commit);
  Bool has_commit = rime->get_commit(session, &commit);
  if (has_commit && commit.text) {
    commit_text = commit.text;
  }

  RIME_STRUCT(RimeContext, context);
  if (!rime->get_context(session, &context)) {
    fprintf(stderr, "failed to read Rime context\n");
    if (has_commit) {
      rime->free_commit(&commit);
    }
    rime->destroy_session(session);
    rime->finalize();
    return 1;
  }

  printf("schema=%s\n", schema_id);
  printf("commit=%s\n", commit_text);
  printf("preedit=%s\n", context.composition.preedit ? context.composition.preedit : "");
  printf("candidates=%d page_size=%d\n", context.menu.num_candidates, context.menu.page_size);
  for (int i = 0; i < context.menu.num_candidates; ++i) {
    printf("candidate[%d]=%s", i + 1, context.menu.candidates[i].text ? context.menu.candidates[i].text : "");
    if (context.menu.candidates[i].comment && context.menu.candidates[i].comment[0]) {
      printf("\t%s", context.menu.candidates[i].comment);
    }
    printf("\n");
  }

  rime->free_context(&context);
  if (has_commit) {
    rime->free_commit(&commit);
  }
  rime->destroy_session(session);
  rime->finalize();
  return 0;
}
