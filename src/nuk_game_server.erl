%%%-------------------------------------------------------------------
%% @doc `nuk_game_server' module
%%
%% When a nuk game session is created, a new process is spawned that keeps the
%% general nuk state and the arbitrary game engine state. It is also
%% responsible for processing significant events during the lifetime of the
%% game, triggering appropriate {@link nuk_game_engine} callbacks, and
%% processing their results. This is the `gen_server' module that accomplishes
%% the above.
%%
%% For public API to accessing this functionality use the {@link nuk_games}
%% module. Do not call the functions of this module directly.
%% @end
%%%-------------------------------------------------------------------

-module(nuk_game_server).

-behaviour(gen_server).

%% API
-export([create/3]).
-export([start/2]).
-export([join/2]).
-export([leave/2]).
-export([get_session/2]).
-export([turn/3]).

%% Supervision
-export([start_link/1, init/1]).

%% Behavior callbacks
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-type state() :: #{session_id => string(), session => nuk_game_session:session()}.

%%====================================================================
%% Supervision
%%====================================================================

start_link(GameName) ->
    gen_server:start_link(?MODULE, [GameName], []).

-spec init([GameName :: string()]) -> {ok, State :: state()}.
init([GameName]) ->
    {ok, Game} = nuk_games:get(GameName),
    {ok, #{session_id => "", session => nuk_game_session:new(Game)}}.

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new game session
%%
%% Given a user, name of the game and list of options, creates a new game
%% session. This function does 2 things:
%%    - starts a new `nuk_game_server' child via {@link nuk_game_sup}
%%    - sends itself an `initialize' message to invoke the game engine to
%%      obtain the initial game state
%%
%% Calling this function triggers the {@link nuk_game_engine:initialize/2}
%% callback.
%%
%% For public API {@link nuk_games:create/2} or {@link nuk_games:create/3} must
%% be used.
%% @end
-spec create(User :: nuk_user:user(), GameName :: string(), Options :: list()) ->
    {ok, GameSessionId :: string()} |
    {error, invalid_game_name, Extra :: string()} |
    {error, invalid_options, Extra :: string()}.
create(User, GameName, Options) ->
    {ok, Pid} = supervisor:start_child(nuk_game_sup, [GameName]),
    %% NOTE we make another gen_server call here for 2 reasons:
    %% - we need to invoke the `nuk_game_engine:initialize/2' callback and it
    %%   is not a good practice to potentially block init/1 with an external
    %%   call
    %% - so that we can return responses during failures - i.e. if we did
    %%   everything in init we wouldn't be able to return the error details
    %%   from server
    gen_server:call(Pid, {initialize, User, Options}).

%% @doc Join a user to the game session
%%
%% This is a function powering the implementation of {@link nuk_games:join/2}.
%% It adds the given user to the current game session after validating that
%%    - user hasn't already joined the game
%%    - maximum number of users allowed by the game wouldn't be exceeded
%%
%% Calling this function triggers the {@link nuk_game_engine:player_join/3}
%% callback.
%%
%% For public API {@link nuk_games:join/2} must be used.
%% @end
-spec join(Pid :: pid(), User :: nuk_user:user()) ->
    ok |
    {error, user_already_joined, Extra :: string()} |
    {error, max_users_reached, Extra :: string()}.
join(Pid, User) ->
    gen_server:call(Pid, {player_join, User}).

%% @doc Remove a user from the game session
%%
%% This is a function powering the implementation of {@link nuk_games:leave/2}.
%% It removes a given user from the current game session after validating that
%% user is in the current game session.
%%
%% Calling this function triggers the {@link nuk_game_engine:player_leave/3}
%% callback.
%%
%% For public API {@link nuk_games:leave/2} must be used.
%% @end
-spec leave(Pid :: pid(), User :: nuk_user:user()) ->
    ok |
    {error, user_not_in_game, Extra :: string()}.
leave(Pid, User) ->
    gen_server:call(Pid, {player_leave, User}).

%% @doc Start a game
%%
%% This is a function powering the implementation of {@link nuk_games:start/2}.
%% It starts the current game session after validating that the user requesting
%% the action is in the current game session.
%%
%% Calling this function triggers the {@link nuk_game_engine:start/2} callback.
%%
%% For public API {@link nuk_games:start/2} must be used.
%% @end
-spec start(Pid :: pid(), User :: nuk_user:user()) ->
    ok |
    {error, user_not_in_game, Extra :: string()}.
start(Pid, User) ->
    gen_server:call(Pid, {start, User}).

%% @doc Get a snapshot of game session
%%
%% This is a function powering the implementation of
%% {@link nuk_games:get_game_session/2}. It returns the current snapshot of
%% the general nuk game session state and arbitrary game engine state.
%%
%% For public API {@link nuk_games:get_game_session/2} must be used.
%% @end
-spec get_session(Pid :: pid(), User :: nuk_user:user()) ->
    nuk_game_session:session().
get_session(Pid, User) ->
    gen_server:call(Pid, {get_session, User}).

%% @doc Process player's turn
%%
%% This is a function powering the implementation of {@link nuk_games:turn/3}.
%% It takes and processes a turn for a given player after verifying that the
%% given player may make a turn at current stage of the game.
%%
%% Calling this function triggers the {@link nuk_game_engine:turn/4} callback.
%% The game engine may return the `invalid_turn' error if the turn data is
%% not acceptable.
%%
%% For public API {@link nuk_games:turn/3} must be used.
%% @end
-spec turn(Pid :: pid(), User :: nuk_user:user(), Turn :: term()) ->
    ok |
    {error, user_not_in_game, Extra :: string()} |
    {error, bad_turn_order, Extra :: string()} |
    {error, invalid_turn, Extra :: string()}.
turn(Pid, User, Turn) ->
    gen_server:call(Pid, {turn, User, Turn}).

%%====================================================================
%% Behavior callbacks
%%====================================================================

handle_call({initialize, User, Options}, _From,
            #{session := GameSession} = State) ->
    %% NOTE further minor optimization is possible by setting game module in state
    GameModule = get_game_engine_module(GameSession),
    case GameModule:initialize(User, Options) of
        {error, invalid_options, Reason} ->
            {stop, normal, {error, invalid_options, Reason}, State};
        {ok, GameState} ->
            GameSession1 = nuk_game_session:set_game_state(GameSession, GameState),
            GameSession2 = nuk_game_session:set_players(GameSession1, [User]),
            GameSession3 = nuk_game_session:set_status(GameSession2, initialized),
            GameSessionId = nuk_game_sessions:put(self()),
            StateNew = State#{session_id := GameSessionId, session := GameSession3},
            {reply, {ok, GameSessionId}, StateNew}
    end;
handle_call({player_join, User}, _From, #{session := GameSession} = State) ->
    case check_user_can_join(GameSession, User) of
        {error, ErrorCode, Reason} ->
            {reply, {error, ErrorCode, Reason}, State};
        ok ->
            GameModule = get_game_engine_module(GameSession),
            GameState = nuk_game_session:get_game_state(GameSession),
            NukState = nuk_game_session:get_nuk_state(GameSession),
            case GameModule:player_join(User, GameState, NukState) of
                {error, ErrorCode, Reason} ->
                    {reply, {error, ErrorCode, Reason}, State};
                {ok, GameStateNew} ->
                    GameSession1 = nuk_game_session:set_game_state(GameSession,
                                                                   GameStateNew),
                    GameSession2 = nuk_game_session:add_player(GameSession1, User),
                    StateNew = State#{session := GameSession2},
                    {reply, ok, StateNew}
            end
    end;
handle_call({player_leave, User}, _From, #{session := GameSession} = State) ->
    case check_user_can_leave(GameSession, User) of
        {error, user_not_in_game, Reason} ->
            {reply, {error, user_not_in_game, Reason}, State};
        ok ->
            GameModule = get_game_engine_module(GameSession),
            GameState = nuk_game_session:get_game_state(GameSession),
            NukState = nuk_game_session:get_nuk_state(GameSession),
            %% TODO below logic w/minor variation is repeated between player_leave and turn
            case GameModule:player_leave(User, GameState, NukState) of
                {error, game_already_started, Reason} ->
                    {reply, {error, game_already_started, Reason}, State};
                {ok, await_turn, NextTurnPlayers, GameStateNew} ->
                    GameSession1 = nuk_game_session:set_game_state(GameSession,
                                                                   GameStateNew),
                    GameSession2 = nuk_game_session:set_status(GameSession1,
                                                               await_turn),
                    GameSession3 = nuk_game_session:set_players_turn(GameSession2,
                                                                     NextTurnPlayers),
                    GameSession4 = nuk_game_session:remove_player(GameSession3, User),
                    StateNew = State#{session := GameSession4},
                    {reply, ok, StateNew};
                {ok, complete, Winners, Losers, GameStateNew} ->
                    GameSession1 = nuk_game_session:set_game_state(GameSession,
                                                                   GameStateNew),
                    GameSession2 = nuk_game_session:set_status(GameSession1, complete),
                    GameSession3 = nuk_game_session:set_winners_losers(GameSession2,
                                                                       Winners,
                                                                       Losers),
                    GameSession4 = nuk_game_session:set_players_turn(GameSession3, []),
                    GameSession5 = nuk_game_session:remove_player(GameSession4, User),
                    StateNew = State#{session := GameSession5},
                    ok = finish_game(),
                    {reply, ok, StateNew}
            end
    end;
handle_call({start, User}, _From, #{session := GameSession} = State) ->
    case check_user_can_start(GameSession, User) of
        {error, user_not_in_game, Reason} ->
            {reply, {error, user_not_in_game, Reason}, State};
        ok ->
            GameModule = get_game_engine_module(GameSession),
            GameState = nuk_game_session:get_game_state(GameSession),
            NukState = nuk_game_session:get_nuk_state(GameSession),
            {ok, await_turn, NextTurnPlayers, GameStateNew} =
                GameModule:start(GameState, NukState),
            GameSession1 = nuk_game_session:set_game_state(GameSession, GameStateNew),
            GameSession2 = nuk_game_session:set_status(GameSession1, await_turn),
            GameSession3 = nuk_game_session:set_players_turn(GameSession2,
                                                             NextTurnPlayers),
            GameSession4 = nuk_game_session:increment_turn_number(GameSession3),
            StateNew = State#{session := GameSession4},
            {reply, ok, StateNew}
    end;
handle_call({get_session, User}, _From, #{session := GameSession} = State) ->
    Username = nuk_user:get_username(User),
    GameState = nuk_game_session:get_game_state(GameSession),
    GameStateFiltered = filter_for_player(GameState, Username),
    GameSessionFiltered = nuk_game_session:set_game_state(GameSession,
                                                          GameStateFiltered),
    {reply, GameSessionFiltered, State};
handle_call({turn, User, Turn}, _From, #{session := GameSession} = State) ->
    case check_user_can_turn(GameSession, User) of
        {error, ErrorCode, Reason} ->
            {reply, {error, ErrorCode, Reason}, State};
        ok ->
            GameModule = get_game_engine_module(GameSession),
            GameState = nuk_game_session:get_game_state(GameSession),
            NukState = nuk_game_session:get_nuk_state(GameSession),
            case GameModule:turn(User, Turn, GameState, NukState) of
                {error, ErrorCode, Reason} ->
                    {reply, {error, ErrorCode, Reason}, State};
                {ok, await_turn, NextTurnPlayers, GameStateNew} ->
                    GameSession1 = nuk_game_session:set_game_state(GameSession,
                                                                   GameStateNew),
                    GameSession2 = nuk_game_session:set_status(GameSession1,
                                                               await_turn),
                    GameSession3 = nuk_game_session:set_players_turn(GameSession2,
                                                                     NextTurnPlayers),
                    GameSession4 = nuk_game_session:increment_turn_number(GameSession3),
                    StateNew = State#{session := GameSession4},
                    {reply, ok, StateNew};
                {ok, complete, Winners, Losers, GameStateNew} ->
                    GameSession1 = nuk_game_session:set_game_state(GameSession,
                                                                   GameStateNew),
                    GameSession2 = nuk_game_session:set_status(GameSession1, complete),
                    GameSession3 = nuk_game_session:set_winners_losers(GameSession2,
                                                                       Winners,
                                                                       Losers),
                    GameSession4 = nuk_game_session:set_players_turn(GameSession3, []),
                    StateNew = State#{session := GameSession4},
                    ok = finish_game(),
                    {reply, ok, StateNew}
            end
    end.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(finish, #{session := GameSession} = State) ->
    GameModule = get_game_engine_module(GameSession),
    GameState = nuk_game_session:get_game_state(GameSession),
    NukState = nuk_game_session:get_nuk_state(GameSession),
    GameModule:finish(GameState, NukState),
    {stop, normal, State};
handle_info(_Msg, State) -> {noreply, State}.

terminate(_Reason, #{session_id := GameSessionId} = _State) ->
    nuk_game_sessions:delete(GameSessionId),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @doc Get game engine module
%% @private
%%
%% Extracts registered game engine module from the {@link nuk_game:game()} data
%% type stored in current game session.
%% @end
-spec get_game_engine_module(GameSession :: nuk_game_session:session()) -> atom().
get_game_engine_module(GameSession) ->
    Game = nuk_game_session:get_game(GameSession),
    nuk_game:get_module(Game).

%% @doc Get max # of players
%% @private
%%
%% Extracts maximum number of players allowed per game registration.
%% @end
-spec get_max_players(GameSession :: nuk_game_session:session()) -> integer().
get_max_players(GameSession) ->
    Game = nuk_game_session:get_game(GameSession),
    nuk_game:get_max_players(Game).

%% @doc Check whether a given user can join this game session
%% @private
%%
%% Verifies user is not already part of the game session and maximum number
%% of players hasn't been reached.
%% @end
-spec check_user_can_join(GameSession :: nuk_game_session:session(),
                          User :: nuk_user:user()) ->
    ok |
    {error, user_already_joined, Extra :: string()} |
    {error, max_users_reached, Extra :: string()}.
check_user_can_join(GameSession, User) ->
    case nuk_game_session:has_player(GameSession, User) of
        true ->
            {error, user_already_joined, "User already joined the game"};
        false ->
            MaxPlayers = get_max_players(GameSession),
            CurrentPlayersCount = nuk_game_session:get_players_count(GameSession),
            if
                CurrentPlayersCount < MaxPlayers ->
                    ok;
                true ->
                    {error, max_users_reached, "Maximum number of users reached"}
            end
    end.

%% @doc Check whether a user can leave the game session
%% @private
%%
%% Checks that user is currently joined to the game session.
%% @end
-spec check_user_can_leave(GameSession :: nuk_game_session:session(),
                           User :: nuk_user:user()) ->
    ok |
    {error, user_not_in_game, Extra :: string()}.
check_user_can_leave(GameSession, User) ->
    check_user_can_act(GameSession, User).

%% @doc Check whether user can start the game
%% @private
%%
%% Checks that user is currently joined to the game session.
%% @end
-spec check_user_can_start(GameSession :: nuk_game_session:session(),
                           User :: nuk_user:user()) ->
    ok |
    {error, user_not_in_game, Extra :: string()}.
check_user_can_start(GameSession, User) ->
    check_user_can_act(GameSession, User).

%% @doc Check whether user can make a turn
%% @private
%%
%% Checks that user is currently joined to the game session, and that it is
%% expected the user can make the turn.
%% @end
-spec check_user_can_turn(GameSession :: nuk_game_session:session(),
                          User :: nuk_user:user()) ->
    ok |
    {error, user_not_in_game, Extra :: string()} |
    {error, bad_turn_order, Extra :: string()}.
check_user_can_turn(GameSession, User) ->
    case check_user_can_act(GameSession, User) of
        {error, user_not_in_game, Reason} ->
            {error, user_not_in_game, Reason};
        ok ->
            case nuk_game_session:is_players_turn(GameSession, User) of
                false ->
                    {error, bad_turn_order, "It is not your turn"};
                true ->
                    ok
            end
    end.

%% @doc Check whether user can perform an action
%% @private
%%
%% Checks that user is currently joined to the game session.
%% @end
-spec check_user_can_act(GameSession :: nuk_game_session:session(),
                         User :: nuk_user:user()) ->
    ok |
    {error, user_not_in_game, Extra :: string()}.
check_user_can_act(GameSession, User) ->
    case nuk_game_session:has_player(GameSession, User) of
        false ->
            {error, user_not_in_game, "User has not joined this game"};
        true ->
            ok
    end.

%% @doc Filter state for specific player
%% @private
%%
%% Filters the full game state down to strip game engine private data, and
%% private state of other players so it is suitable for consumption by an
%% individual player.
-spec filter_for_player(GameState :: nuk_game_engine_state:state(),
                        Username :: string()) ->
    nuk_game_engine_state:state().
filter_for_player(GameState, Username) ->
    StatePrivate = [],
    StatePublic = nuk_game_engine_state:get_public(GameState),
    StatePlayer = nuk_game_engine_state:get_player(GameState, Username),
    StatePlayers = #{Username => StatePlayer},
    nuk_game_engine_state:new(StatePrivate, StatePublic, StatePlayers).

%% @doc Finish the game after delay
%% @private
%%
%% Sends the `finish' message to itself after a 5 second delay.
%% @end
-spec finish_game() -> ok.
finish_game() ->
    _Ref = erlang:send_after(5000, self(), finish),
    ok.
