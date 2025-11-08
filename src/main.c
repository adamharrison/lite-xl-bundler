#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifdef PACKED_LUA
  extern const char* packed_luac[];
#else
  static const char* packed_luac[] = { NULL, NULL, NULL };
#endif

int luaopen_wtk_server_driver(lua_State* L);
int luaopen_wtk_proc(lua_State* L);
int luaopen_wtk_json(lua_State* L);
int luaopen_wtk_dbix_dbd_sqlite3(lua_State* L);

static lua_State* L;

static void handle_exit(int sig) {
  static int entered = 0;
  if (!entered) {
    entered = 1;
    lua_close(L);
  }
  exit(0);
}

int main(int argc, char* argv[]) {
  L = luaL_newstate();
  luaL_openlibs(L);
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, luaopen_wtk_server_driver);
  lua_setfield(L, -2, "wtk.server.driver");
  lua_pushcfunction(L, luaopen_wtk_proc);
  lua_setfield(L, -2, "wtk.proc");
  lua_pushcfunction(L, luaopen_wtk_json);
  lua_setfield(L, -2, "wtk.json");
  lua_pushcfunction(L, luaopen_wtk_dbix_dbd_sqlite3);
  lua_setfield(L, -2, "wtk.dbix.dbd.sqlite3");
  for (int i = 0; packed_luac[i]; i += 3) {
    if (luaL_loadbuffer(L, packed_luac[i+1], (size_t)packed_luac[i+2], packed_luac[i])) {
      fprintf(stderr, "Error loading %s: %s", packed_luac[i], lua_tostring(L, -1));
      return -1;
    }
    lua_setfield(L, -2, packed_luac[i]);
  }
  lua_pop(L, 1);
  if (luaL_loadstring(L, "(package.preload.init or loadfile(\"init.lua\"))(...)")) {
    fprintf(stderr, "error loading server: %s\n", lua_tostring(L, -1));
    return -1;
  }
  for (int i = 1; i < argc; ++i) 
    lua_pushstring(L, argv[i]);
  signal(SIGINT, handle_exit);
  signal(SIGTERM, handle_exit);
  signal(SIGPIPE, SIG_IGN);
  if (lua_pcall(L, argc - 1, LUA_MULTRET, 0))
    fprintf(stderr, "error initializing server: %s\n", lua_tostring(L, -1));
  handle_exit(SIGTERM);
  return 0;
}
