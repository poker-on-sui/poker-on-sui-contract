module poker::game;

use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::random::{Random, new_generator};
use sui::sui::SUI;

// Constants for game configuration
const MIN_PLAYERS: u64 = 2;
const MAX_PLAYERS: u64 = 8;
const CARDS_PER_PLAYER: u64 = 2;
const SEED_LENGTH: u64 = 32;
const MIN_BUY_IN: u64 = 100_000_000; // 0.1 SUI

// ===== Game Constants =====

// Error codes
const EGameInProgress: u64 = 0x0000;
const EInvalidPlayerCount: u64 = 0x0001;
const EInsufficientBuyIn: u64 = 0x0002;
const EInvalidPlayer: u64 = 0x0004;
const EInvalidAction: u64 = 0x0005;
const EInvalidAmount: u64 = 0x0006;
const ENotYourTurn: u64 = 0x0007;
const EAlreadyJoined: u64 = 0x0009;
const EInvalidSeed: u64 = 0x000A;
const EInvalidGameState: u64 = 0x000B;
const EInvalidHandSize: u64 = 0x000C;

// Player actions
const ACTION_FOLD: u8 = 0;
const ACTION_CHECK: u8 = 1;
const ACTION_CALL: u8 = 2;
const ACTION_BET_OR_RAISE: u8 = 3;

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

// ===== Game Structs =====

/// Card representation
///
/// - Suit: 0 = Hearts, 1 = Diamonds, 2 = Clubs, 3 = Spades
/// - Value: 2-14 (2-10, Jack=11, Queen=12, King=13, Ace=14)
public struct Card has copy, drop, store {
  suit: u8,
  value: u8,
}

// Hand evaluation result
public struct HandRank has copy, drop, store {
  hand_type: u8, // Type of hand (0-9)
  primary_value: u8, // Primary value for comparison (e.g., pair value, high card)
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
  id: UID,
  players: vector<Player>,
  deck: vector<Card>,
  community_cards: vector<Card>,
  pot: Balance<SUI>,
  side_pots: vector<SidePot>,
  buy_in: u64,
  min_bet: u64,
  /// Current bet amount for the round. Will be reset to 0 at the start of each betting round.
  current_bet: u64,
  small_blind: u64,
  big_blind: u64,
  dealer_position: u64,
  current_player: u64,
  state: u8,
  last_raise_position: u64,
  owner: address,
}

// ===== Events =====

public struct GameCreated has copy, drop {
  game_id: ID,
  buy_in: u64,
}

public struct PlayerJoined has copy, drop {
  game_id: ID,
  player: address,
}

public struct GameStarted has copy, drop {
  game_id: ID,
  num_players: u64,
}

public struct PlayerMoved has copy, drop {
  game_id: ID,
  player: address,
  action: u8,
  amount: u64,
}

public struct RoundChanged has copy, drop {
  game_id: ID,
  new_state: u8,
}

public struct GameEnded has copy, drop {
  game_id: ID,
  winners: vector<address>,
  amounts: vector<u64>,
}

public struct PlayerWithdrawn has copy, drop {
  game_id: ID,
  player: address,
  balance: u64,
}

// ===== Accessors =====

public fun get_state(game: &PokerGame): u8 { game.state }

public fun get_buy_in(game: &PokerGame): u64 { game.buy_in }

public fun get_dealer_position(game: &PokerGame): u64 { game.dealer_position }

public fun get_pot_balance(game: &PokerGame): u64 { game.pot.value() }

// Alias for accessors
public use fun get_state as PokerGame.state;
public use fun get_buy_in as PokerGame.buy_in;
public use fun get_dealer_position as PokerGame.dealer_position;
public use fun get_pot_balance as PokerGame.pot_balance;
// ===== Game Functions =====

/// Create a new poker game
public entry fun create(payment: Coin<SUI>, ctx: &mut TxContext): ID {
  let id = object::new(ctx);
  let game_id = id.to_inner();
  let owner_addr = ctx.sender();

  // Calculate derived values from buy_in
  let buy_in = payment.value();
  let min_bet = buy_in / 20; // 5% of buy_in
  let small_blind = min_bet / 2; // 50% of min_bet
  let big_blind = min_bet; // 100% of min_bet

  // Check buy-in amount for creator
  assert!(buy_in >= MIN_BUY_IN, EInsufficientBuyIn);

  let game = PokerGame {
    id,
    players: vector[
      Player {
        addr: owner_addr, // Creator automatically joins the game
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
    pot: payment.into_balance(), // Create the initial pot with creator's payment
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
    owner: owner_addr,
  };

  emit(GameCreated { game_id, buy_in });
  emit(PlayerJoined { game_id, player: owner_addr });

  transfer::share_object(game);

  game_id
}

// Join an existing poker game
public entry fun join(
  game: &mut PokerGame,
  payment: Coin<SUI>,
  ctx: &mut TxContext,
) {
  let player_addr = ctx.sender();

  // Check game state
  assert!(game.state == STATE_WAITING_FOR_PLAYERS, EGameInProgress);

  // Check if player count is valid
  assert!(game.players.length() < MAX_PLAYERS, EInvalidPlayerCount);

  // Check if player already joined
  let mut i = 0;
  let len = game.players.length();
  while (i < len) {
    let player = game.players.borrow(i);
    assert!(player.addr != player_addr, EAlreadyJoined);
    i = i + 1;
  };

  // Check buy-in amount
  assert!(payment.value() >= game.buy_in, EInsufficientBuyIn);

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
  emit(PlayerJoined { game_id, player: player_addr });
}

public entry fun cancel_game(game: PokerGame, ctx: &mut TxContext) {
  // Only owner can cancel the game
  assert!(ctx.sender() == game.owner, EInvalidPlayer);

  // Check if game is still waiting for players
  assert!(game.state == STATE_WAITING_FOR_PLAYERS, EInvalidGameState);

  // Emit event and delete the game
  let game_id = game.id.to_inner();
  emit(GameEnded { game_id, winners: vector[], amounts: vector[] });
  let PokerGame { id, pot, .. } = game;
  transfer::public_transfer(pot.into_coin(ctx), ctx.sender());
  id.delete();
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

  assert!(
    player_count >= MIN_PLAYERS && player_count <= MAX_PLAYERS,
    EInvalidPlayerCount,
  );

  assert!(seed.length() == SEED_LENGTH, EInvalidSeed);
  assert!(game.state == STATE_WAITING_FOR_PLAYERS, EInvalidGameState);

  // Only owner can start the game
  assert!(ctx.sender() == game.owner, EInvalidPlayer);

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
  let game_id = game.id.to_inner();
  emit(GameStarted { game_id, num_players: player_count });
  emit(RoundChanged { game_id, new_state: game.state });
}

// ===== Player Actions =====

/// Withdraw balance from the game
entry fun withdraw(game: &mut PokerGame, ctx: &mut TxContext) {
  assert!(game.state == STATE_GAME_OVER, EInvalidGameState); // Game must be over to claim pot
  let player_addr = ctx.sender();
  let player_index = find_player_index(game, player_addr);
  let player = game.players.borrow_mut(player_index);
  let amount = player.balance;
  assert!(amount > 0, EInvalidAction); // Player must have winnings to withdraw
  assert!(game.pot.value() >= amount, EInvalidAction); // Check if pot has enough balance
  player.balance = 0; // Reset player balance to 0
  let winnings = game.pot.split(amount).into_coin(ctx);
  transfer::public_transfer(winnings, player_addr); // Take balance from game pot to player's coin
  emit(PlayerWithdrawn {
    game_id: game.id.to_inner(),
    player: player_addr,
    balance: amount,
  });
}

// Player action: fold
public entry fun fold(game: &mut PokerGame, ctx: &mut TxContext) {
  let player_addr = ctx.sender();
  let player_index = find_player_index(game, player_addr);
  assert!(can_act(game, player_index), ENotYourTurn);
  let player = game.players.borrow_mut(player_index);
  player.is_folded = true;
  complete_player_action(game, player_addr, ACTION_FOLD, 0);
}

// Player action: check
public entry fun check(game: &mut PokerGame, ctx: &mut TxContext) {
  let player_addr = ctx.sender();
  let player_index = find_player_index(game, player_addr);
  assert!(can_act(game, player_index), ENotYourTurn);
  let player = game.players.borrow(player_index);
  assert!(game.current_bet == player.current_bet, EInvalidAction); // Cannot "check" if current bet is not equal to other players's bet
  complete_player_action(game, player_addr, ACTION_CHECK, 0);
}

// Player action: call
public entry fun call(game: &mut PokerGame, ctx: &mut TxContext) {
  let player_addr = ctx.sender();
  let player_index = find_player_index(game, player_addr);
  assert!(can_act(game, player_index), ENotYourTurn);
  let player = game.players.borrow_mut(player_index);
  let call_amount = std::u64::min(
    game.current_bet - player.current_bet, // Amount needed to call
    player.balance, // Use available balance if its lesser (all-in scenario)
  );
  player.balance = player.balance - call_amount;
  player.current_bet = player.current_bet + call_amount;
  player.total_contributed = player.total_contributed + call_amount;
  if (player.balance == 0) player.is_all_in = true;
  complete_player_action(game, player_addr, ACTION_CALL, call_amount);
}

// Player action: bet or raise
public entry fun bet_or_raise(
  game: &mut PokerGame,
  amount: u64,
  ctx: &mut TxContext,
) {
  let player_addr = ctx.sender();
  let player_index = find_player_index(game, player_addr);
  assert!(can_act(game, player_index), ENotYourTurn);
  assert!(amount >= game.min_bet, EInvalidAmount);
  let player = game.players.borrow_mut(player_index);
  assert!(amount <= player.balance, EInvalidAmount);
  assert!(player.current_bet + amount > game.current_bet, EInvalidAction); // Amount must be enough to raise the game's current bet
  player.balance = player.balance - amount;
  player.current_bet = player.current_bet + amount;
  player.total_contributed = player.total_contributed + amount;
  game.current_bet = player.current_bet; // Update current bet to player's bet
  game.last_raise_position = player_index;
  if (player.balance == 0) player.is_all_in = true;
  complete_player_action(game, player_addr, ACTION_BET_OR_RAISE, amount);
}

// Helper function to complete player action (emit event and advance game)
fun complete_player_action(
  game: &mut PokerGame,
  player_addr: address,
  action: u8,
  amount: u64,
) {
  emit(PlayerMoved {
    game_id: game.id.to_inner(),
    player: player_addr,
    action,
    amount,
  });
  let next_player = get_next_active_player(game);
  if (next_player.is_some()) game.current_player = next_player.destroy_some();
  if (is_round_complete(game)) advance_game_state(game);
}

// ===== Helper Functions =====

fun initialize_deck(game: &mut PokerGame) {
  // Clear the deck first
  game.deck = vector[];

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
  let mut seed = vector[];
  let mut i = 0;
  while (i < SEED_LENGTH) {
    let byte = generator.generate_u8();
    seed.push_back(byte);
    i = i + 1;
  };
  seed
}

/// Shuffle the deck of cards
fun shuffle_deck(game: &mut PokerGame, seed: vector<u8>) {
  let deck_size = game.deck.length();
  let hash = sui::hash::keccak256(&seed);
  let mut i = deck_size;

  while (i > 1) {
    i = i - 1;
    let seed_byte = *hash.borrow(i % hash.length());
    let j = ((seed_byte as u64) + i) % i;
    game.deck.swap(i, j);
  }
}

/// Deal cards to each player
fun deal_player_cards(game: &mut PokerGame) {
  let player_count = game.players.length();

  // Deal 2 cards to each player
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow_mut(i);
    player.cards = vector[]; // Reset cards

    let mut j = 0;
    while (j < CARDS_PER_PLAYER) {
      let card = game.deck.pop_back();
      player.cards.push_back(card);
      j = j + 1;
    };

    i = i + 1;
  }
}

/// Collect blinds from players
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

/// Find player index by address. Abort with `EInvalidPlayer` if not found.
fun find_player_index(game: &PokerGame, addr: address): u64 {
  let mut i = 0;
  while (i < game.players.length()) {
    let player = game.players.borrow(i);
    if (player.addr == addr) { return i };
    i = i + 1;
  };
  abort EInvalidPlayer
}

/// Check if the player can take action or not.
fun can_act(game: &PokerGame, player_index: u64): bool {
  game.state >= STATE_PRE_FLOP &&
  game.state <= STATE_RIVER &&
  game.current_player == player_index &&
  game.players.borrow(player_index).is_folded == false
}

/// Update the game's current player to the next active player.
fun get_next_active_player(game: &PokerGame): Option<u64> {
  let player_count = game.players.length();
  let mut next_player = (game.current_player + 1) % player_count;
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow(next_player);
    if (!player.is_folded && !player.is_all_in)
      return option::some(next_player); // Found the closest active player
    next_player = (next_player + 1) % player_count; // Else, move to next player and check again
    i = i + 1;
  };
  option::none() // No active players found
}

/// Check if the current round is complete (all players have acted or folded)
fun is_round_complete(game: &PokerGame): bool {
  let player_count = game.players.length();

  // Take index of all active players (not folded and not all-in)
  let mut active_players: vector<u64> = vector[];
  let mut i = 0;
  while (i < player_count) {
    let player = game.players.borrow(i);
    if (!player.is_folded && !player.is_all_in) {
      active_players.push_back(i);
    };
    i = i + 1;
  };
  // If only 0 or 1 active players, round is complete
  if (active_players.length() <= 1) return true;

  // Check if all active players have matched the current bet
  let mut i = 0;
  while (i < active_players.length()) {
    let player_index = *active_players.borrow(i);
    let player = game.players.borrow(player_index);
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

  emit(RoundChanged { game_id, new_state: game.state });
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
      if (!bet_levels.contains(&player.total_contributed)) {
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
  while (level_idx < bet_levels.length()) {
    let current_level = *bet_levels.borrow(level_idx);
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
    let pot_amount = pot_contribution_per_player * eligible_players.length();

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
  let len = levels.length();
  let mut i = 0;
  while (i < len) {
    let mut j = i + 1;
    while (j < len) {
      if (*levels.borrow(i) > *levels.borrow(j)) {
        levels.swap(i, j);
      };
      j = j + 1;
    };
    i = i + 1;
  };
}

/// Rotate dealer position and reset for new hand
public entry fun start_new_hand(game: &mut PokerGame, ctx: &mut TxContext) {
  // Can only start new hand if current game is over
  assert!(game.state == STATE_GAME_OVER, EInvalidGameState);

  // Only owner can start new hand
  assert!(ctx.sender() == game.owner, EInvalidPlayer);

  let player_count = game.players.length();
  assert!(player_count >= MIN_PLAYERS, EInvalidPlayerCount);

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
  emit(GameStarted { game_id, num_players: player_count });
  emit(RoundChanged { game_id, new_state: game.state });
}

// Simple shuffle without external randomness for new hands
fun simple_shuffle_deck(game: &mut PokerGame) {
  let deck_size = game.deck.length();
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

  let mut winners = vector[];
  let mut amounts = vector[];

  if (active_count == 1) {
    // Only one player left, they win the whole pot
    let mut i = 0;
    while (i < player_count) {
      let player = game.players.borrow(i);
      if (!player.is_folded) {
        let winner_addr = player.addr;
        let pot_amount = game.pot.value();

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
    let pot_count = game.side_pots.length();
    let mut pot_idx = 0;

    while (pot_idx < pot_count) {
      let side_pot = game.side_pots.borrow(pot_idx);
      let eligible_players = &side_pot.eligible_players;
      let pot_amount = side_pot.amount;

      if (pot_amount == 0 || eligible_players.length() == 0) {
        pot_idx = pot_idx + 1;
        continue
      };

      // Evaluate hands for eligible players only
      let mut eligible_hands = vector[];
      let mut eligible_addresses = vector[];

      let mut e = 0;
      while (e < eligible_players.length()) {
        let player_idx = *eligible_players.borrow(e);
        let player = game.players.borrow(player_idx);

        if (!player.is_folded) {
          // Create 7-card hand (2 hole cards + 5 community cards)
          let mut hand_cards = vector[];
          hand_cards.push_back(player.cards[0]);
          hand_cards.push_back(player.cards[1]);

          let mut j = 0;
          while (j < game.community_cards.length()) {
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
      let mut best_hand_indices: vector<u64> = vector[];

      if (eligible_hands.length() > 0) {
        // Start with first hand as best
        best_hand_indices.push_back(0);

        // Compare with remaining hands
        let mut k = 1;
        while (k < eligible_hands.length()) {
          let current_hand = eligible_hands.borrow(k);
          let best_hand = eligible_hands.borrow(
            *best_hand_indices.borrow(0),
          );

          if (compare_hands(current_hand, best_hand)) {
            // Current hand is better
            best_hand_indices = vector[];
            best_hand_indices.push_back(k);
          } else if (!compare_hands(best_hand, current_hand)) {
            // Tie
            best_hand_indices.push_back(k);
          };

          k = k + 1;
        };
      };

      // Distribute this side pot among winners
      let winner_count = best_hand_indices.length();
      if (winner_count > 0) {
        let share = pot_amount / winner_count;

        let mut w = 0;
        while (w < winner_count) {
          let hand_idx = *best_hand_indices.borrow(w);
          let eligible_idx = *eligible_players.borrow(hand_idx);
          let winner_addr = *eligible_addresses.borrow(hand_idx);

          // Check if this winner is already in our winners list
          let mut found = false;
          let mut winners_idx = 0;
          while (winners_idx < winners.length()) {
            if (*winners.borrow(winners_idx) == winner_addr) {
              // Add to existing amount
              let current_amount = amounts.borrow_mut(winners_idx);
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
  emit(GameEnded { game_id, winners, amounts });

  // Set game state to game over
  game.state = STATE_GAME_OVER;
}

// ===== Hand Evaluation Functions =====

/// Evaluate a 7-card hand (5 community + 2 hole cards) and return the best 5-card hand
fun evaluate_hand(cards: &vector<Card>): HandRank {
  assert!(cards.length() == 7, EInvalidHandSize);

  // Convert cards to ranks and suits for evaluation
  let mut ranks: vector<u8> = vector[];
  let mut suits: vector<u8> = vector[];

  let mut i = 0;
  while (i < 7) {
    let card = cards.borrow(i);
    ranks.push_back(card.value);
    suits.push_back(card.suit);
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
      kickers: vector[],
    }
  };

  // Check for straight flush
  if (is_flush && is_straight) {
    return HandRank {
      hand_type: HAND_STRAIGHT_FLUSH,
      primary_value: straight_high,
      secondary_value: 0,
      kickers: vector[],
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
      kickers: vector[],
    }
  };

  // Check for flush
  if (is_flush) {
    let flush_kickers = get_flush_kickers(&ranks, &suits, flush_suit);
    return HandRank {
      hand_type: HAND_FLUSH,
      primary_value: *flush_kickers.borrow(0),
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
      kickers: vector[],
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
  if (pairs.length() >= 2) {
    let high_pair = *pairs.borrow(0);
    let low_pair = *pairs.borrow(1);
    let kicker = find_highest_kicker(&ranks, high_pair, 1);
    let kicker2 = find_highest_kicker(&ranks, low_pair, 1);
    let final_kicker = if (kicker != low_pair && kicker != high_pair) kicker
    else kicker2;

    return HandRank {
      hand_type: HAND_TWO_PAIR,
      primary_value: high_pair,
      secondary_value: low_pair,
      kickers: vector[final_kicker],
    }
  };

  // Check for one pair
  if (pairs.length() == 1) {
    let pair_rank = *pairs.borrow(0);
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
    primary_value: *kickers.borrow(0),
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
  let len = ranks.length();
  let mut i = 0;
  while (i < len) {
    let mut j = i + 1;
    while (j < len) {
      if (*ranks.borrow(i) < *ranks.borrow(j)) {
        ranks.swap(i, j);
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
  while (i < suits.length()) {
    let suit = *suits.borrow(i);
    let current_count = *suit_counts.borrow(suit as u64);
    *suit_counts.borrow_mut(suit as u64) = current_count + 1;
    i = i + 1;
  };

  i = 0;
  while (i < 4) {
    if (*suit_counts.borrow(i) >= 5) {
      return (i as u8)
    };
    i = i + 1;
  };

  255 // No flush
}

/// Check for straight and return the high card (0 if no straight)
fun check_straight(ranks: &vector<u8>): u8 {
  // Remove duplicates and sort
  let mut unique_ranks = vector[];
  let mut i = 0;
  while (i < ranks.length()) {
    let rank = *ranks.borrow(i);
    if (!unique_ranks.contains(&rank)) {
      unique_ranks.push_back(rank);
    };
    i = i + 1;
  };

  sort_ranks(&mut unique_ranks);

  // Check for 5 consecutive cards
  let unique_length = unique_ranks.length();
  if (unique_length < 5) {
    return 0 // Not enough unique ranks for a straight
  };

  i = 0;
  while (i <= unique_length - 5) {
    let mut consecutive = true;
    let mut j = 0;
    while (j < 4) {
      let current_rank = *unique_ranks.borrow(i + j);
      let next_rank = *unique_ranks.borrow(i + j + 1);
      if (current_rank != next_rank + 1) {
        consecutive = false;
        break
      };
      j = j + 1;
    };

    if (consecutive) {
      return *unique_ranks.borrow(i) // Return high card of straight
    };
    i = i + 1;
  };

  // Check for A-2-3-4-5 straight (wheel)
  if (unique_ranks.length() >= 5) {
    let has_ace = unique_ranks.contains(&14);
    let has_five = unique_ranks.contains(&5);
    let has_four = unique_ranks.contains(&4);
    let has_three = unique_ranks.contains(&3);
    let has_two = unique_ranks.contains(&2);

    if (has_ace && has_five && has_four && has_three && has_two) {
      return 5 // 5-high straight
    };
  };

  0 // No straight
}

/// Count frequency of each rank
fun count_ranks(ranks: &vector<u8>): vector<u8> {
  let mut counts: vector<u8> = vector[];
  let mut i = 0;
  while (i < 15) {
    counts.push_back(0);
    i = i + 1;
  };

  i = 0;
  while (i < ranks.length()) {
    let rank = *ranks.borrow(i);
    let current_count = *counts.borrow(rank as u64);
    *counts.borrow_mut(rank as u64) = current_count + 1;
    i = i + 1;
  };

  counts
}

/// Find four of a kind rank (0 if none)
fun find_four_of_a_kind(rank_counts: &vector<u8>): u8 {
  let mut i = 14;
  while (i >= 2) {
    if (*rank_counts.borrow(i) == 4) {
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
    if (*rank_counts.borrow(i) == 3) {
      three_kind = (i as u8);
      break
    };
    i = i - 1;
  };

  // Find pair (highest, different from three of a kind)
  i = 14;
  while (i >= 2) {
    let count = *rank_counts.borrow(i);
    if (
      (count == 2 || (count == 3 && (i as u8) != three_kind)) && (i as u8) != three_kind
    ) {
      pair_value = (i as u8);
      break
    };
    i = i - 1;
  };

  (three_kind, pair_value)
}

/// Find pairs in descending order
fun find_pairs(rank_counts: &vector<u8>): vector<u8> {
  let mut pairs: vector<u8> = vector[];

  let mut i = 14;
  while (i >= 2) {
    let count = *rank_counts.borrow(i);
    if (count == 2) {
      pairs.push_back(i as u8);
    } else if (count == 3) {
      // Three of a kind counts as a pair for full house detection
      pairs.push_back(i as u8);
    };
    i = i - 1;
  };

  pairs
}

/// Find the highest kicker excluding specified rank
fun find_highest_kicker(ranks: &vector<u8>, exclude_rank: u8, count: u8): u8 {
  let kickers = find_kickers(ranks, exclude_rank, count);
  if (kickers.length() > 0) {
    *kickers.borrow(0)
  } else {
    0
  }
}

/// Find kickers (cards not part of the main hand)
fun find_kickers(ranks: &vector<u8>, exclude_rank: u8, count: u8): vector<u8> {
  let mut kickers: vector<u8> = vector[];

  // Collect unused ranks in descending order
  let mut i = 0;
  let target_count = (count as u64);
  while (i < ranks.length() && kickers.length() < target_count) {
    let rank = *ranks.borrow(i);
    if (rank != exclude_rank) {
      kickers.push_back(rank);
    };
    i = i + 1;
  };

  kickers
}

/// Get flush kickers (5 highest cards of flush suit)
fun get_flush_kickers(
  ranks: &vector<u8>,
  suits: &vector<u8>,
  flush_suit: u8,
): vector<u8> {
  let mut flush_cards = vector[];

  let mut i = 0;
  while (i < suits.length()) {
    if (*suits.borrow(i) == flush_suit) {
      flush_cards.push_back(*ranks.borrow(i));
    };
    i = i + 1;
  };

  sort_ranks(&mut flush_cards);

  // Take top 5 cards
  let mut kickers = vector[];
  i = 0;
  while (i < 5 && i < flush_cards.length()) {
    kickers.push_back(*flush_cards.borrow(i));
    i = i + 1;
  };

  kickers
}

/// Get high card kickers (5 highest cards)
fun get_high_card_kickers(ranks: &vector<u8>): vector<u8> {
  let mut unique_ranks: vector<u8> = vector[];

  // Get unique ranks
  let mut i = 0;
  while (i < ranks.length()) {
    let rank = *ranks.borrow(i);
    if (!unique_ranks.contains(&rank)) {
      unique_ranks.push_back(rank);
    };
    i = i + 1;
  };

  sort_ranks(&mut unique_ranks);

  // Take top 5
  let mut kickers = vector[];
  i = 0;
  while (i < 5 && i < unique_ranks.length()) {
    kickers.push_back(*unique_ranks.borrow(i));
    i = i + 1;
  };

  kickers
}

/// Compare kickers arrays
fun compare_kickers(kickers1: &vector<u8>, kickers2: &vector<u8>): bool {
  let len = kickers1.length();
  let mut i = 0;
  while (i < len && i < kickers2.length()) {
    let k1 = *kickers1.borrow(i);
    let k2 = *kickers2.borrow(i);
    if (k1 != k2) {
      return k1 > k2
    };
    i = i + 1;
  };
  false // Tie
}
