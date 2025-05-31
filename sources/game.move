module poker::game;

use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::random::{new_generator, Random};
use sui::sui::SUI;

// Constants for game configuration
const MIN_PLAYERS: u64 = 2;
const MAX_PLAYERS: u64 = 8;
const CARDS_PER_PLAYER: u64 = 2;
const SEED_LENGTH: u64 = 32;

// Error codes
const EGameInProgress: u64 = 0x0000;
const EInvalidPlayerCount: u64 = 0x0001;
const EInsufficientBuyIn: u64 = 0x0002;
const EInvalidPlayer: u64 = 0x0004;
const EInvalidAction: u64 = 0x0005;
const EInvalidBet: u64 = 0x0006;
const ENotYourTurn: u64 = 0x0007;
const EAlreadyJoined: u64 = 0x0009;
const EInvalidSeed: u64 = 0x000A;
const EInvalidGameState: u64 = 0x000B;
const EInvalidHandSize: u64 = 0x000C;

// Card representation
// Suit: 0 = Hearts, 1 = Diamonds, 2 = Clubs, 3 = Spades
// Value: 2-14 (2-10, Jack=11, Queen=12, King=13, Ace=14)
public struct Card has copy, drop, store {
  suit: u8,
  value: u8,
}

// Player actions
const ACTION_FOLD: u8 = 0;
const ACTION_CHECK: u8 = 1;
const ACTION_CALL: u8 = 2;
const ACTION_BET: u8 = 3;
const ACTION_RAISE: u8 = 4;

// Game states
const STATE_WAITING_FOR_PLAYERS: u8 = 0;
const STATE_PRE_FLOP: u8 = 2;
const STATE_FLOP: u8 = 3;
const STATE_TURN: u8 = 4;
const STATE_RIVER: u8 = 5;
const STATE_SHOWDOWN: u8 = 6;
const STATE_GAME_OVER: u8 = 7;

// Hand ranking constants
const HAND_HIGH_CARD: u8 = 0;
const HAND_ONE_PAIR: u8 = 1;
const HAND_TWO_PAIR: u8 = 2;
const HAND_THREE_OF_A_KIND: u8 = 3;
const HAND_STRAIGHT: u8 = 4;
const HAND_FLUSH: u8 = 5;
const HAND_FULL_HOUSE: u8 = 6;
const HAND_FOUR_OF_A_KIND: u8 = 7;
const HAND_STRAIGHT_FLUSH: u8 = 8;
const HAND_ROYAL_FLUSH: u8 = 9;

// Hand evaluation result
public struct HandRank has copy, drop, store {
  hand_type: u8,      // Type of hand (0-9)
  primary_value: u8,   // Primary value for comparison (e.g., pair value, high card)
  secondary_value: u8, // Secondary value (e.g., kicker for pair, second pair for two pair)
  kickers: vector<u8>, // Additional kickers for tie-breaking
}

// Side pot information for all-in scenarios
public struct SidePot has drop, store {
  amount: u64,
  eligible_players: vector<u64>, // Player indices eligible for this pot
}

// Player information
public struct Player has drop, store {
  addr: address,
  cards: vector<Card>,
  balance: u64,
  current_bet: u64,
  total_contributed: u64, // Total amount contributed to all pots this hand
  is_folded: bool,
  is_all_in: bool,
}

// Main game object
public struct PokerGame has key {
  id: sui::object::UID,
  players: vector<Player>,
  deck: vector<Card>,
  community_cards: vector<Card>,
  pot: Balance<SUI>,
  side_pots: vector<SidePot>,
  buy_in: u64,
  min_bet: u64,
  current_bet: u64,
  small_blind: u64,
  big_blind: u64,
  dealer_position: u64,
  current_player: u64,
  state: u8,
  last_raise_position: u64,
  owner: address,
}

// Event declarations
public struct GameCreated has copy, drop {
  game_id: sui::object::ID,
  buy_in: u64,
}

public struct PlayerJoined has copy, drop {
  game_id: sui::object::ID,
  player: address,
}

public struct GameStarted has copy, drop {
  game_id: sui::object::ID,
  num_players: u64,
}

public struct PlayerMoved has copy, drop {
  game_id: sui::object::ID,
  player: address,
  action: u8,
  amount: u64,
}

public struct RoundChanged has copy, drop {
  game_id: sui::object::ID,
  new_state: u8,
}

public struct GameEnded has copy, drop {
  game_id: sui::object::ID,
  winners: vector<address>,
  amounts: vector<u64>,
}

// Create a new poker game
public entry fun create_game(buy_in: u64, ctx: &mut TxContext) {
  let id = sui::object::new(ctx);
  let game_id = sui::object::uid_to_inner(&id);

  // Calculate derived values from buy_in
  let min_bet = buy_in / 20; // 5% of buy_in
  let small_blind = min_bet / 2; // 50% of min_bet
  let big_blind = min_bet; // 100% of min_bet

  let game = PokerGame {
    id,
    players: vector[
      Player {
        addr: ctx.sender(),
        cards: vector[],
        balance: buy_in,
        current_bet: 0,
        total_contributed: 0,
        is_folded: false,
        is_all_in: false,
      },
    ],
    deck: vector[],
    community_cards: vector[],
    pot: balance::zero(),
    side_pots: vector[],
    buy_in,
    min_bet,
    current_bet: 0,
    small_blind,
    big_blind,
    dealer_position: 0,
    current_player: 0,
    state: STATE_WAITING_FOR_PLAYERS,
    last_raise_position: 0,
    owner: ctx.sender(),
  };

  sui::event::emit(GameCreated { game_id, buy_in });

  sui::transfer::share_object(game);
}

// Join an existing poker game
public entry fun join_game(
  game: &mut PokerGame,
  payment: Coin<SUI>,
  ctx: &mut TxContext,
) {
  let player_addr = ctx.sender();

  // Check game state
  if (game.state != STATE_WAITING_FOR_PLAYERS) {
    abort EGameInProgress
  };

  // Check if player count is valid
  if (std::vector::length(&game.players) >= MAX_PLAYERS) {
    abort EInvalidPlayerCount
  };

  // Check if player already joined
  let mut i = 0;
  let len = std::vector::length(&game.players);
  while (i < len) {
    let player = std::vector::borrow(&game.players, i);
    if (player.addr == player_addr) {
      abort EAlreadyJoined
    };
    i = i + 1;
  };

  // Check buy-in amount
  if (payment.value() < game.buy_in) {
    abort EInsufficientBuyIn
  };

  // Add player to the game
  let player = Player {
    addr: player_addr,
    cards: vector[],
    balance: game.buy_in,
    current_bet: 0,
    total_contributed: 0,
    is_folded: false,
    is_all_in: false,
  };
  game.players.push_back(player);

  // Add payment to pot
  let payment_balance = payment.into_balance();
  game.pot.join(payment_balance);

  // Emit event
  let game_id = game.id.to_inner();
  sui::event::emit(PlayerJoined { game_id, player: player_addr });
}

// Start the poker game if we have enough players
entry fun start_game(game: &mut PokerGame, r: &Random, ctx: &mut TxContext) {
  let seed = generate_seed(r, ctx);
  start_game_with_seed(game, seed, ctx)
}

#[test_only]
public entry fun start_game_with_seed_for_testing(
  game: &mut PokerGame,
  seed: vector<u8>,
  ctx: &TxContext,
) {
  start_game_with_seed(game, seed, ctx);
}

entry fun start_game_with_seed(
  game: &mut PokerGame,
  seed: vector<u8>,
  ctx: &TxContext,
) {
  let player_count = game.players.length();

  if (player_count < MIN_PLAYERS || player_count > MAX_PLAYERS) {
    abort EInvalidPlayerCount
  };

  if (seed.length() != SEED_LENGTH) abort EInvalidSeed;
  if (game.state != STATE_WAITING_FOR_PLAYERS) abort EInvalidGameState;

  // Only owner can start the game
  if (ctx.sender() != game.owner) abort EInvalidPlayer;

  initialize_deck(game);

  // Shuffle the deck
  shuffle_deck(game, seed);

  // Deal cards to players
  deal_player_cards(game);

  // Set blinds
  collect_blinds(game);

  // Update game state
  game.state = STATE_PRE_FLOP;

  // Set current player (after big blind)
  game.current_player = (game.dealer_position + 3) % player_count;
  game.last_raise_position = (game.dealer_position + 2) % player_count; // Big blind is the last raiser

  // Emit event
  let game_id = sui::object::uid_to_inner(&game.id);
  sui::event::emit(GameStarted { game_id, num_players: player_count });
  sui::event::emit(RoundChanged { game_id, new_state: game.state });
}

// Helper function to validate player action prerequisites
fun validate_player_action(game: &PokerGame, ctx: &TxContext): u64 {
  // Validate game state
  if (game.state < STATE_PRE_FLOP || game.state > STATE_RIVER) {
    abort EInvalidGameState
  };

  let player_addr = ctx.sender();
  let player_count = std::vector::length(&game.players);
  let player_index = find_player_index(game, player_addr);

  // Validate player
  if (player_index >= player_count) {
    abort EInvalidPlayer
  };
  if (player_index != game.current_player) {
    abort ENotYourTurn
  };

  let player = std::vector::borrow(&game.players, player_index);
  if (player.is_folded) {
    abort EInvalidAction
  };

  player_index
}

// Helper function to complete player action (emit event and advance game)
fun complete_player_action(
  game: &mut PokerGame,
  player_addr: address,
  action: u8,
  amount: u64,
) {
  // Emit action event
  let game_id = sui::object::uid_to_inner(&game.id);
  sui::event::emit(PlayerMoved {
    game_id,
    player: player_addr,
    action,
    amount,
  });

  // Move to next player
  move_to_next_player(game);

  // Check if round is complete
  if (is_round_complete(game)) {
    advance_game_state(game);
  }
}

// Player action: fold
public entry fun fold(
  game: &mut PokerGame,
  ctx: &mut TxContext,
) {
  let player_index = validate_player_action(game, ctx);
  let player_addr = ctx.sender();

  let player = std::vector::borrow_mut(&mut game.players, player_index);
  player.is_folded = true;

  complete_player_action(game, player_addr, ACTION_FOLD, 0);
}

// Player action: check
public entry fun check(
  game: &mut PokerGame,
  ctx: &mut TxContext,
) {
  let player_index = validate_player_action(game, ctx);
  let player_addr = ctx.sender();

  let player = std::vector::borrow(&game.players, player_index);
  if (game.current_bet != player.current_bet) {
    abort EInvalidAction
  };

  complete_player_action(game, player_addr, ACTION_CHECK, 0);
}

// Player action: call
public entry fun call(
  game: &mut PokerGame,
  ctx: &mut TxContext,
) {
  let player_index = validate_player_action(game, ctx);
  let player_addr = ctx.sender();

  let player = std::vector::borrow_mut(&mut game.players, player_index);
  let call_amount = game.current_bet - player.current_bet;
  
  if (call_amount > player.balance) {
    abort EInvalidBet
  };

  player.balance = player.balance - call_amount;
  player.current_bet = game.current_bet;
  player.total_contributed = player.total_contributed + call_amount;
  if (player.balance == 0) {
    player.is_all_in = true;
  };

  complete_player_action(game, player_addr, ACTION_CALL, call_amount);
}

// Player action: bet
public entry fun bet(
  game: &mut PokerGame,
  amount: u64,
  ctx: &mut TxContext,
) {
  let player_index = validate_player_action(game, ctx);
  let player_addr = ctx.sender();

  // For a bet, there should be no current bet
  if (game.current_bet != 0) {
    abort EInvalidAction
  };

  // Validate minimum bet amount
  if (amount < game.min_bet) {
    abort EInvalidBet
  };

  let player = std::vector::borrow_mut(&mut game.players, player_index);
  
  // Check if player has enough balance for bet
  if (amount > player.balance + player.current_bet) {
    abort EInvalidBet
  };

  let additional_amount = amount - player.current_bet;
  player.balance = player.balance - additional_amount;
  player.current_bet = amount;
  player.total_contributed = player.total_contributed + additional_amount;
  game.current_bet = amount;
  game.last_raise_position = player_index;

  if (player.balance == 0) {
    player.is_all_in = true;
  };

  complete_player_action(game, player_addr, ACTION_BET, amount);
}

// Player action: raise
public entry fun raise(
  game: &mut PokerGame,
  amount: u64,
  ctx: &mut TxContext,
) {
  let player_index = validate_player_action(game, ctx);
  let player_addr = ctx.sender();

  // For a raise, there should be a current bet and the raise should be at least min_bet
  if (game.current_bet == 0) {
    abort EInvalidAction
  };
  if (amount < game.current_bet + game.min_bet) {
    abort EInvalidBet
  };

  let player = std::vector::borrow_mut(&mut game.players, player_index);
  
  // Check if player has enough balance for raise
  if (amount > player.balance + player.current_bet) {
    abort EInvalidBet
  };

  let additional_amount = amount - player.current_bet;
  player.balance = player.balance - additional_amount;
  player.current_bet = amount;
  player.total_contributed = player.total_contributed + additional_amount;
  game.current_bet = amount;
  game.last_raise_position = player_index;

  if (player.balance == 0) {
    player.is_all_in = true;
  };

  complete_player_action(game, player_addr, ACTION_RAISE, amount);
}

// ===== Helper Functions =====

fun initialize_deck(game: &mut PokerGame) {
  // Clear the deck first
  game.deck = vector::empty();

  // Create a standard 52-card deck
  let mut suit = 0;
  while (suit < 4) {
    let mut value = 2;
    while (value <= 14) {
      let card = Card { suit: (suit as u8), value: (value as u8) };
      game.deck.push_back(card);
      value = value + 1;
    };
    suit = suit + 1;
  }
}

entry fun generate_seed(r: &Random, ctx: &mut TxContext): vector<u8> {
  let mut generator = new_generator(r, ctx);
  let mut seed = vector::empty<u8>();
  let mut i = 0;
  while (i < SEED_LENGTH) {
    let byte = generator.generate_u8();
    seed.push_back(byte);
    i = i + 1;
  };
  seed
}

fun shuffle_deck(game: &mut PokerGame, seed: vector<u8>) {
  let deck_size = vector::length(&game.deck);
  let hash = sui::hash::keccak256(&seed);
  let mut i = deck_size;

  while (i > 1) {
    i = i - 1;
    let seed_byte = *vector::borrow(&hash, i % hash.length());
    let j = ((seed_byte as u64) + i) % i;
    game.deck.swap(i, j);
  }
}

fun deal_player_cards(game: &mut PokerGame) {
  let player_count = game.players.length();

  // Deal 2 cards to each player
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow_mut(i);
    player.cards = vector::empty(); // Reset cards

    let mut j = 0;
    while (j < CARDS_PER_PLAYER) {
      let card = game.deck.pop_back();
      player.cards.push_back(card);
      j = j + 1;
    };

    i = i + 1;
  }
}

fun collect_blinds(game: &mut PokerGame) {
  let player_count = game.players.length();

  // Small blind
  let sb_pos = (game.dealer_position + 1) % player_count;
  let player = game.players.borrow_mut(sb_pos);
  let sb_amount = if (player.balance < game.small_blind) { player.balance }
  else {
    game.small_blind
  };
  player.balance = player.balance - sb_amount;
  player.current_bet = sb_amount;
  player.total_contributed = player.total_contributed + sb_amount;
  if (player.balance == 0) {
    player.is_all_in = true;
  };

  // Big blind
  let bb_pos = (game.dealer_position + 2) % player_count;
  let player = game.players.borrow_mut(bb_pos);
  let bb_amount = if (player.balance < game.big_blind) { player.balance } else {
    game.big_blind
  };
  player.balance = player.balance - bb_amount;
  player.current_bet = bb_amount;
  player.total_contributed = player.total_contributed + bb_amount;
  if (player.balance == 0) {
    player.is_all_in = true;
  };

  // Set current bet to big blind
  game.current_bet = bb_amount;
}

fun find_player_index(game: &PokerGame, addr: address): u64 {
  let mut i = 0;
  let len = game.players.length();

  while (i < len) {
    let player = game.players.borrow(i);
    if (player.addr == addr) {
      return i
    };
    i = i + 1;
  };

  return len // Return invalid index if not found
}

fun move_to_next_player(game: &mut PokerGame) {
  let player_count = game.players.length();
  let mut next_player = (game.current_player + 1) % player_count;

  // Skip folded or all-in players
  let mut checked = 0;
  while (checked < player_count) {
    let player = game.players.borrow(next_player);
    if (!player.is_folded && !player.is_all_in) {
      break
    };
    next_player = (next_player + 1) % player_count;
    checked = checked + 1;
  };

  game.current_player = next_player;
}

fun is_round_complete(game: &PokerGame): bool {
  let player_count = game.players.length();

  // Count active players (not folded and not all-in)
  let mut active_players = 0;
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow(i);
    if (!player.is_folded && !player.is_all_in) {
      active_players = active_players + 1;
    };
    i = i + 1;
  };

  // If only 0 or 1 active players, round is complete
  if (active_players <= 1) {
    return true
  };

  // Check if all active players have matched the current bet
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow(i);
    if (
      !player.is_folded && !player.is_all_in && player.current_bet != game.current_bet
    ) {
      return false
    };
    i = i + 1;
  };

  // All active players have matched the bet
  // Now check if we've completed a betting cycle

  if (game.state == STATE_PRE_FLOP) {
    // Pre-flop: round is complete when current player has cycled back
    // to the player after the big blind (first to act)
    let first_to_act_preflop = (game.dealer_position + 3) % player_count;
    return game.current_player == first_to_act_preflop
  } else {
    // Post-flop rounds: round is complete when action returns to last raiser
    // or if no one has bet (current_bet = 0), when we complete a full cycle
    if (game.current_bet == 0) {
      // No betting this round - complete when we cycle back to first active player
      let first_to_act_postflop = (game.dealer_position + 1) % player_count;
      let mut first_active = first_to_act_postflop;
      while (true) {
        let player = game.players.borrow(first_active);
        if (!player.is_folded && !player.is_all_in) {
          break
        };
        first_active = (first_active + 1) % player_count;
        if (first_active == first_to_act_postflop) {
          break
        };
      };
      return game.current_player == first_active
    } else {
      // Someone has bet/raised - round complete when action returns to last raiser
      return game.current_player == game.last_raise_position
    }
  }
}

fun advance_game_state(game: &mut PokerGame) {
  let game_id = game.id.to_inner();

  reset_player_bets(game);

  // Check if only one player remains
  if (count_active_players(game) == 1) {
    // Game over - one winner
    game.state = STATE_GAME_OVER;
    distribute_pot(game);
    return
  };

  // Otherwise, advance to next stage
  if (game.state == STATE_PRE_FLOP) {
    // Deal the flop (3 community cards)
    deal_community_cards(game, 3);
    game.state = STATE_FLOP;
  } else if (game.state == STATE_FLOP) {
    // Deal the turn (1 community card)
    deal_community_cards(game, 1);
    game.state = STATE_TURN;
  } else if (game.state == STATE_TURN) {
    // Deal the river (1 community card)
    deal_community_cards(game, 1);
    game.state = STATE_RIVER;
  } else if (game.state == STATE_RIVER) {
    // Showdown
    game.state = STATE_SHOWDOWN;
    distribute_pot(game);
    return
  };

  // Reset for next betting round
  game.current_bet = 0;
  let player_count = game.players.length();
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow_mut(i);
    player.current_bet = 0;
    i = i + 1;
  };

  // Set current player for next round (first active player after dealer)
  game.current_player = (game.dealer_position + 1) % player_count;
  while (true) {
    let player = game.players.borrow(game.current_player);
    if (!player.is_folded && !player.is_all_in) {
      break
    };
    game.current_player = (game.current_player + 1) % player_count;
  };

  sui::event::emit(RoundChanged { game_id, new_state: game.state });
}

fun reset_player_bets(game: &mut PokerGame) {
  let player_count = game.players.length();

  // Reset all players' current_bet to 0 for the next betting round
  let mut j = 0;
  while (j < player_count) {
    let player = game.players.borrow_mut(j);
    player.current_bet = 0;
    j = j + 1;
  };
}

// Create side pots for all-in scenarios
fun create_side_pots(game: &mut PokerGame) {
  let player_count = game.players.length();
  game.side_pots = vector[];
  
  // Collect all unique bet amounts from active players (not folded)
  let mut bet_levels = vector<u64>[];
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow(i);
    if (!player.is_folded && player.total_contributed > 0) {
      if (!vector::contains(&bet_levels, &player.total_contributed)) {
        bet_levels.push_back(player.total_contributed);
      };
    };
    i = i + 1;
  };
  
  // Sort bet levels in ascending order
  sort_bet_levels(&mut bet_levels);
  
  // Create side pots for each bet level
  let mut prev_level = 0u64;
  let mut level_idx = 0;
  while (level_idx < vector::length(&bet_levels)) {
    let current_level = *vector::borrow(&bet_levels, level_idx);
    let pot_contribution_per_player = current_level - prev_level;
    
    // Find eligible players for this pot level
    let mut eligible_players = vector<u64>[];
    let mut j = 0;
    while (j < player_count) {
      let player = game.players.borrow(j);
      if (!player.is_folded && player.total_contributed >= current_level) {
        eligible_players.push_back(j);
      };
      j = j + 1;
    };
    
    // Calculate pot amount
    let pot_amount = pot_contribution_per_player * vector::length(&eligible_players);
    
    if (pot_amount > 0) {
      let side_pot = SidePot {
        amount: pot_amount,
        eligible_players,
      };
      game.side_pots.push_back(side_pot);
    };
    
    prev_level = current_level;
    level_idx = level_idx + 1;
  };
}

// Sort bet levels in ascending order
fun sort_bet_levels(levels: &mut vector<u64>) {
  let len = vector::length(levels);
  let mut i = 0;
  while (i < len) {
    let mut j = i + 1;
    while (j < len) {
      if (*vector::borrow(levels, i) > *vector::borrow(levels, j)) {
        vector::swap(levels, i, j);
      };
      j = j + 1;
    };
    i = i + 1;
  };
}

// Rotate dealer position and reset for new hand
public entry fun start_new_hand(game: &mut PokerGame, ctx: &mut TxContext) {
  // Can only start new hand if current game is over
  if (game.state != STATE_GAME_OVER) {
    abort EInvalidGameState
  };
  
  // Only owner can start new hand
  if (ctx.sender() != game.owner) {
    abort EInvalidPlayer
  };
  
  let player_count = game.players.length();
  if (player_count < MIN_PLAYERS) {
    abort EInvalidPlayerCount
  };
  
  // Rotate dealer position
  game.dealer_position = (game.dealer_position + 1) % player_count;
  
  // Reset game state for new hand
  reset_for_new_hand(game);
  
  // Initialize and shuffle deck with simple rotation-based shuffle
  initialize_deck(game);
  simple_shuffle_deck(game);
  
  // Deal new cards
  deal_player_cards(game);
  
  // Collect blinds with rotation
  collect_blinds(game);
  
  // Set game state to pre-flop
  game.state = STATE_PRE_FLOP;
  
  // Set current player (after big blind)
  game.current_player = (game.dealer_position + 3) % player_count;
  game.last_raise_position = (game.dealer_position + 2) % player_count;
  
  // Emit events
  let game_id = game.id.to_inner();
  sui::event::emit(GameStarted { game_id, num_players: player_count });
  sui::event::emit(RoundChanged { game_id, new_state: game.state });
}

// Simple shuffle without external randomness for new hands
fun simple_shuffle_deck(game: &mut PokerGame) {
  let deck_size = vector::length(&game.deck);
  let mut i = 0;
  
  // Simple deterministic shuffle based on dealer position
  while (i < deck_size) {
    let j = (i + game.dealer_position + 7) % deck_size;
    if (i != j) {
      game.deck.swap(i, j);
    };
    i = i + 1;
  };
}

// Reset all game state for a new hand
fun reset_for_new_hand(game: &mut PokerGame) {
  let player_count = game.players.length();
  let mut i = 0;
  
  // Reset all player states
  while (i < player_count) {
    let player = game.players.borrow_mut(i);
    player.cards = vector[];
    player.current_bet = 0;
    player.total_contributed = 0;
    player.is_folded = false;
    player.is_all_in = false;
    i = i + 1;
  };
  
  // Reset game state
  game.community_cards = vector[];
  game.side_pots = vector[];
  game.current_bet = 0;
  game.last_raise_position = 0;
}

fun count_active_players(game: &PokerGame): u64 {
  let player_count = game.players.length();
  let mut active_players = 0;

  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow(i);
    if (!player.is_folded) {
      active_players = active_players + 1;
    };
    i = i + 1;
  };

  active_players
}

fun deal_community_cards(game: &mut PokerGame, count: u64) {
  let mut i = 0;
  while (i < count) {
    let card = game.deck.pop_back();
    game.community_cards.push_back(card);
    i = i + 1;
  }
}

fun distribute_pot(game: &mut PokerGame) {
  let player_count = game.players.length();
  let active_count = count_active_players(game);

  let mut winners = vector::empty<address>();
  let mut amounts = vector::empty<u64>();

  if (active_count == 1) {
    // Only one player left, they win the whole pot
    let mut i = 0;
    while (i < player_count) {
      let player = game.players.borrow(i);
      if (!player.is_folded) {
        let winner_addr = player.addr;
        let pot_amount = balance::value(&game.pot);

        winners.push_back(winner_addr);
        amounts.push_back(pot_amount);

        // Credit the pot amount to the winner's balance
        let p = game.players.borrow_mut(i);
        p.balance = p.balance + pot_amount;
        
        break
      };
      i = i + 1;
    }
  } else {
    // Create side pots for all-in scenarios
    create_side_pots(game);
    
    // Distribute each side pot
    let pot_count = vector::length(&game.side_pots);
    let mut pot_idx = 0;
    
    while (pot_idx < pot_count) {
      let side_pot = vector::borrow(&game.side_pots, pot_idx);
      let eligible_players = &side_pot.eligible_players;
      let pot_amount = side_pot.amount;
      
      if (pot_amount == 0 || vector::length(eligible_players) == 0) {
        pot_idx = pot_idx + 1;
        continue
      };
      
      // Evaluate hands for eligible players only
      let mut eligible_hands = vector::empty<HandRank>();
      let mut eligible_addresses = vector::empty<address>();
      
      let mut e = 0;
      while (e < vector::length(eligible_players)) {
        let player_idx = *vector::borrow(eligible_players, e);
        let player = game.players.borrow(player_idx);
        
        if (!player.is_folded) {
          // Create 7-card hand (2 hole cards + 5 community cards)
          let mut hand_cards = vector::empty<Card>();
          hand_cards.push_back(player.cards[0]);
          hand_cards.push_back(player.cards[1]);
          
          let mut j = 0;
          while (j < vector::length(&game.community_cards)) {
            hand_cards.push_back(game.community_cards[j]);
            j = j + 1;
          };
          
          let hand_rank = evaluate_hand(&hand_cards);
          eligible_hands.push_back(hand_rank);
          eligible_addresses.push_back(player.addr);
        };
        e = e + 1;
      };
      
      // Find best hands among eligible players
      let mut best_hand_indices = vector::empty<u64>();
      
      if (vector::length(&eligible_hands) > 0) {
        // Start with first hand as best
        best_hand_indices.push_back(0);
        
        // Compare with remaining hands
        let mut k = 1;
        while (k < vector::length(&eligible_hands)) {
          let current_hand = vector::borrow(&eligible_hands, k);
          let best_hand = vector::borrow(&eligible_hands, *vector::borrow(&best_hand_indices, 0));
          
          if (compare_hands(current_hand, best_hand)) {
            // Current hand is better
            best_hand_indices = vector::empty<u64>();
            best_hand_indices.push_back(k);
          } else if (!compare_hands(best_hand, current_hand)) {
            // Tie
            best_hand_indices.push_back(k);
          };
          
          k = k + 1;
        };
      };
      
      // Distribute this side pot among winners
      let winner_count = vector::length(&best_hand_indices);
      if (winner_count > 0) {
        let share = pot_amount / winner_count;
        
        let mut w = 0;
        while (w < winner_count) {
          let hand_idx = *vector::borrow(&best_hand_indices, w);
          let eligible_idx = *vector::borrow(eligible_players, hand_idx);
          let winner_addr = *vector::borrow(&eligible_addresses, hand_idx);
          
          // Check if this winner is already in our winners list
          let mut found = false;
          let mut winners_idx = 0;
          while (winners_idx < vector::length(&winners)) {
            if (*vector::borrow(&winners, winners_idx) == winner_addr) {
              // Add to existing amount
              let current_amount = vector::borrow_mut(&mut amounts, winners_idx);
              *current_amount = *current_amount + share;
              found = true;
              break
            };
            winners_idx = winners_idx + 1;
          };
          
          if (!found) {
            // Add new winner
            winners.push_back(winner_addr);
            amounts.push_back(share);
          };
          
          // Credit to player balance
          let p = game.players.borrow_mut(eligible_idx);
          p.balance = p.balance + share;
          
          w = w + 1;
        };
      };
      
      pot_idx = pot_idx + 1;
    };
  };

  // Emit game ended event
  let game_id = game.id.to_inner();
  sui::event::emit(GameEnded { game_id, winners, amounts });

  // Set game state to game over
  game.state = STATE_GAME_OVER;
}

// ===== Hand Evaluation Functions =====

  /// Evaluate a 7-card hand (5 community + 2 hole cards) and return the best 5-card hand
  fun evaluate_hand(cards: &vector<Card>): HandRank {
    assert!(vector::length(cards) == 7, EInvalidHandSize);
    
    // Convert cards to ranks and suits for evaluation
    let mut ranks = vector::empty<u8>();
    let mut suits = vector::empty<u8>();
    
    let mut i = 0;
    while (i < 7) {
      let card = vector::borrow(cards, i);
      vector::push_back(&mut ranks, card.value);
      vector::push_back(&mut suits, card.suit);
      i = i + 1;
    };
    
    // Sort ranks for easier evaluation
    sort_ranks(&mut ranks);
    
    // Check for flush
    let flush_suit = check_flush(&suits);
    let is_flush = flush_suit != 255; // 255 indicates no flush
    
    // Check for straight
    let straight_high = check_straight(&ranks);
    let is_straight = straight_high != 0;
    
    // Check for royal flush
    if (is_flush && is_straight && straight_high == 14) {
      return HandRank {
        hand_type: HAND_ROYAL_FLUSH,
        primary_value: 14,
        secondary_value: 0,
        kickers: vector::empty(),
      }
    };
    
    // Check for straight flush
    if (is_flush && is_straight) {
      return HandRank {
        hand_type: HAND_STRAIGHT_FLUSH,
        primary_value: straight_high,
        secondary_value: 0,
        kickers: vector::empty(),
      }
    };
    
    // Count rank frequencies
    let rank_counts = count_ranks(&ranks);
    
    // Check for four of a kind
    let four_kind = find_four_of_a_kind(&rank_counts);
    if (four_kind != 0) {
      let kicker = find_highest_kicker(&ranks, four_kind, 1);
      return HandRank {
        hand_type: HAND_FOUR_OF_A_KIND,
        primary_value: four_kind,
        secondary_value: 0,
        kickers: vector[kicker],
      }
    };
    
    // Check for full house
    let (three_kind, pair_value) = find_full_house(&rank_counts);
    if (three_kind != 0 && pair_value != 0) {
      return HandRank {
        hand_type: HAND_FULL_HOUSE,
        primary_value: three_kind,
        secondary_value: pair_value,
        kickers: vector::empty(),
      }
    };
    
    // Check for flush
    if (is_flush) {
      let flush_kickers = get_flush_kickers(&ranks, &suits, flush_suit);
      return HandRank {
        hand_type: HAND_FLUSH,
        primary_value: *vector::borrow(&flush_kickers, 0),
        secondary_value: 0,
        kickers: flush_kickers,
      }
    };
    
    // Check for straight
    if (is_straight) {
      return HandRank {
        hand_type: HAND_STRAIGHT,
        primary_value: straight_high,
        secondary_value: 0,
        kickers: vector::empty(),
      }
    };
    
    // Check for three of a kind
    if (three_kind != 0) {
      let kickers = find_kickers(&ranks, three_kind, 2);
      return HandRank {
        hand_type: HAND_THREE_OF_A_KIND,
        primary_value: three_kind,
        secondary_value: 0,
        kickers,
      }
    };
    
    // Check for two pair
    let pairs = find_pairs(&rank_counts);
    if (vector::length(&pairs) >= 2) {
      let high_pair = *vector::borrow(&pairs, 0);
      let low_pair = *vector::borrow(&pairs, 1);
      let kicker = find_highest_kicker(&ranks, high_pair, 1);
      let kicker2 = find_highest_kicker(&ranks, low_pair, 1);
      let final_kicker = if (kicker != low_pair && kicker != high_pair) kicker else kicker2;
      
      return HandRank {
        hand_type: HAND_TWO_PAIR,
        primary_value: high_pair,
        secondary_value: low_pair,
        kickers: vector[final_kicker],
      }
    };
    
    // Check for one pair
    if (vector::length(&pairs) == 1) {
      let pair_rank = *vector::borrow(&pairs, 0);
      let kickers = find_kickers(&ranks, pair_rank, 3);
      return HandRank {
        hand_type: HAND_ONE_PAIR,
        primary_value: pair_rank,
        secondary_value: 0,
        kickers,
      }
    };
    
    // High card
    let kickers = get_high_card_kickers(&ranks);
    HandRank {
      hand_type: HAND_HIGH_CARD,
      primary_value: *vector::borrow(&kickers, 0),
      secondary_value: 0,
      kickers,
    }
  }

  /// Compare two hands and return true if hand1 wins
  fun compare_hands(hand1: &HandRank, hand2: &HandRank): bool {
    // Compare hand types first
    if (hand1.hand_type != hand2.hand_type) {
      return hand1.hand_type > hand2.hand_type
    };
    
    // Same hand type, compare primary values
    if (hand1.primary_value != hand2.primary_value) {
      return hand1.primary_value > hand2.primary_value
    };
    
    // Same primary value, compare secondary values
    if (hand1.secondary_value != hand2.secondary_value) {
      return hand1.secondary_value > hand2.secondary_value
    };
    
    // Compare kickers
    compare_kickers(&hand1.kickers, &hand2.kickers)
  }

// ===== Hand Evaluation Helper Functions =====

  /// Sort ranks in descending order (highest first)
  fun sort_ranks(ranks: &mut vector<u8>) {
    let len = vector::length(ranks);
    let mut i = 0;
    while (i < len) {
      let mut j = i + 1;
      while (j < len) {
        if (*vector::borrow(ranks, i) < *vector::borrow(ranks, j)) {
          vector::swap(ranks, i, j);
        };
        j = j + 1;
      };
      i = i + 1;
    };
  }

  /// Check for flush and return the suit (255 if no flush)
  fun check_flush(suits: &vector<u8>): u8 {
    let mut suit_counts = vector[0u8, 0u8, 0u8, 0u8]; // Hearts, Diamonds, Clubs, Spades
    
    let mut i = 0;
    while (i < vector::length(suits)) {
      let suit = *vector::borrow(suits, i);
      let current_count = *vector::borrow(&suit_counts, (suit as u64));
      *vector::borrow_mut(&mut suit_counts, (suit as u64)) = current_count + 1;
      i = i + 1;
    };
    
    i = 0;
    while (i < 4) {
      if (*vector::borrow(&suit_counts, i) >= 5) {
        return (i as u8)
      };
      i = i + 1;
    };
    
    255 // No flush
  }

  /// Check for straight and return the high card (0 if no straight)
  fun check_straight(ranks: &vector<u8>): u8 {
    // Remove duplicates and sort
    let mut unique_ranks = vector::empty<u8>();
    let mut i = 0;
    while (i < vector::length(ranks)) {
      let rank = *vector::borrow(ranks, i);
      if (!vector::contains(&unique_ranks, &rank)) {
        vector::push_back(&mut unique_ranks, rank);
      };
      i = i + 1;
    };
    
    sort_ranks(&mut unique_ranks);
    
    // Check for 5 consecutive cards
    let unique_length = vector::length(&unique_ranks);
    if (unique_length < 5) {
      return 0  // Not enough unique ranks for a straight
    };
    
    i = 0;
    while (i <= unique_length - 5) {
      let mut consecutive = true;
      let mut j = 0;
      while (j < 4) {
        let current_rank = *vector::borrow(&unique_ranks, i + j);
        let next_rank = *vector::borrow(&unique_ranks, i + j + 1);
        if (current_rank != next_rank + 1) {
          consecutive = false;
          break
        };
        j = j + 1;
      };
      
      if (consecutive) {
        return *vector::borrow(&unique_ranks, i) // Return high card of straight
      };
      i = i + 1;
    };
    
    // Check for A-2-3-4-5 straight (wheel)
    if (vector::length(&unique_ranks) >= 5) {
      let has_ace = vector::contains(&unique_ranks, &14);
      let has_five = vector::contains(&unique_ranks, &5);
      let has_four = vector::contains(&unique_ranks, &4);
      let has_three = vector::contains(&unique_ranks, &3);
      let has_two = vector::contains(&unique_ranks, &2);
      
      if (has_ace && has_five && has_four && has_three && has_two) {
        return 5 // 5-high straight
      };
    };
    
    0 // No straight
  }

  /// Count frequency of each rank
  fun count_ranks(ranks: &vector<u8>): vector<u8> {
    let mut counts = vector::empty<u8>();
    let mut i = 0;
    while (i < 15) {
      vector::push_back(&mut counts, 0);
      i = i + 1;
    };
    
    i = 0;
    while (i < vector::length(ranks)) {
      let rank = *vector::borrow(ranks, i);
      let current_count = *vector::borrow(&counts, (rank as u64));
      *vector::borrow_mut(&mut counts, (rank as u64)) = current_count + 1;
      i = i + 1;
    };
    
    counts
  }

  /// Find four of a kind rank (0 if none)
  fun find_four_of_a_kind(rank_counts: &vector<u8>): u8 {
    let mut i = 14;
    while (i >= 2) {
      if (*vector::borrow(rank_counts, i) == 4) {
        return (i as u8)
      };
      i = i - 1;
    };
    0
  }

  /// Find full house (three of a kind, pair)
  fun find_full_house(rank_counts: &vector<u8>): (u8, u8) {
    let mut three_kind = 0u8;
    let mut pair_value = 0u8;
    
    // Find three of a kind (highest)
    let mut i = 14;
    while (i >= 2) {
      if (*vector::borrow(rank_counts, i) == 3) {
        three_kind = (i as u8);
        break
      };
      i = i - 1;
    };
    
    // Find pair (highest, different from three of a kind)
    i = 14;
    while (i >= 2) {
      let count = *vector::borrow(rank_counts, i);
      if ((count == 2 || (count == 3 && (i as u8) != three_kind)) && (i as u8) != three_kind) {
        pair_value = (i as u8);
        break
      };
      i = i - 1;
    };
    
    (three_kind, pair_value)
  }

  /// Find pairs in descending order
  fun find_pairs(rank_counts: &vector<u8>): vector<u8> {
    let mut pairs = vector::empty<u8>();
    
    let mut i = 14;
    while (i >= 2) {
      let count = *vector::borrow(rank_counts, i);
      if (count == 2) {
        vector::push_back(&mut pairs, (i as u8));
      } else if (count == 3) {
        // Three of a kind counts as a pair for full house detection
        vector::push_back(&mut pairs, (i as u8));
      };
      i = i - 1;
    };
    
    pairs
  }

  /// Find the highest kicker excluding specified rank
  fun find_highest_kicker(ranks: &vector<u8>, exclude_rank: u8, count: u8): u8 {
    let kickers = find_kickers(ranks, exclude_rank, count);
    if (vector::length(&kickers) > 0) {
      *vector::borrow(&kickers, 0)
    } else {
      0
    }
  }

  /// Find kickers (cards not part of the main hand)
  fun find_kickers(ranks: &vector<u8>, exclude_rank: u8, count: u8): vector<u8> {
    let mut kickers = vector::empty<u8>();
    
    // Collect unused ranks in descending order
    let mut i = 0;
    let target_count = (count as u64);
    while (i < vector::length(ranks) && vector::length(&kickers) < target_count) {
      let rank = *vector::borrow(ranks, i);
      if (rank != exclude_rank) {
        vector::push_back(&mut kickers, rank);
      };
      i = i + 1;
    };
    
    kickers
  }

  /// Get flush kickers (5 highest cards of flush suit)
  fun get_flush_kickers(ranks: &vector<u8>, suits: &vector<u8>, flush_suit: u8): vector<u8> {
    let mut flush_cards = vector::empty<u8>();
    
    let mut i = 0;
    while (i < vector::length(suits)) {
      if (*vector::borrow(suits, i) == flush_suit) {
        vector::push_back(&mut flush_cards, *vector::borrow(ranks, i));
      };
      i = i + 1;
    };
    
    sort_ranks(&mut flush_cards);
    
    // Take top 5 cards
    let mut kickers = vector::empty<u8>();
    i = 0;
    while (i < 5 && i < vector::length(&flush_cards)) {
      vector::push_back(&mut kickers, *vector::borrow(&flush_cards, i));
      i = i + 1;
    };
    
    kickers
  }

  /// Get high card kickers (5 highest cards)
  fun get_high_card_kickers(ranks: &vector<u8>): vector<u8> {
    let mut unique_ranks = vector::empty<u8>();
    
    // Get unique ranks
    let mut i = 0;
    while (i < vector::length(ranks)) {
      let rank = *vector::borrow(ranks, i);
      if (!vector::contains(&unique_ranks, &rank)) {
        vector::push_back(&mut unique_ranks, rank);
      };
      i = i + 1;
    };
    
    sort_ranks(&mut unique_ranks);
    
    // Take top 5
    let mut kickers = vector::empty<u8>();
    i = 0;
    while (i < 5 && i < vector::length(&unique_ranks)) {
      vector::push_back(&mut kickers, *vector::borrow(&unique_ranks, i));
      i = i + 1;
    };
    
    kickers
  }

  /// Compare kickers arrays
  fun compare_kickers(kickers1: &vector<u8>, kickers2: &vector<u8>): bool {
    let len = vector::length(kickers1);
    let mut i = 0;
    while (i < len && i < vector::length(kickers2)) {
      let k1 = *vector::borrow(kickers1, i);
      let k2 = *vector::borrow(kickers2, i);
      if (k1 != k2) {
        return k1 > k2
      };
      i = i + 1;
    };
    false // Tie
  }
