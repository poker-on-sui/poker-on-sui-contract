module poker::game;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::random::{new_generator, Random};
use sui::sui::SUI;

// Constants for game configuration
const MIN_PLAYERS: u64 = 2;
const MAX_PLAYERS: u64 = 10;
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

// Player information
public struct Player has drop, store {
  addr: address,
  cards: vector<Card>,
  balance: u64,
  current_bet: u64,
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
  buy_in: u64,
  min_bet: u64,
  current_bet: u64,
  small_blind: u64,
  big_blind: u64,
  dealer_position: u64,
  current_player: u64,
  state: u8,
  last_raise_position: u64,
  side_pots: vector<u64>,
  owner: address,
}

// Event declarations
public struct GameCreated has copy, drop {
  game_id: sui::object::ID,
  buy_in: u64,
  min_bet: u64,
  small_blind: u64,
  big_blind: u64,
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
    players: std::vector::empty(),
    deck: std::vector::empty(),
    community_cards: std::vector::empty(),
    pot: balance::zero(),
    buy_in,
    min_bet,
    current_bet: 0,
    small_blind,
    big_blind,
    dealer_position: 0,
    current_player: 0,
    state: STATE_WAITING_FOR_PLAYERS,
    last_raise_position: 0,
    side_pots: std::vector::empty(),
    owner: sui::tx_context::sender(ctx),
  };

  sui::event::emit(GameCreated {
    game_id,
    buy_in,
    min_bet,
    small_blind,
    big_blind,
  });

  sui::transfer::share_object(game);
}

// Join an existing poker game
public entry fun join_game(
  game: &mut PokerGame,
  payment: Coin<SUI>,
  ctx: &mut TxContext,
) {
  let player_addr = sui::tx_context::sender(ctx);

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
  let payment_value = coin::value(&payment);
  if (payment_value < game.buy_in) {
    abort EInsufficientBuyIn
  };

  // Add player to the game
  let player = Player {
    addr: player_addr,
    cards: std::vector::empty(),
    balance: game.buy_in,
    current_bet: 0,
    is_folded: false,
    is_all_in: false,
  };
  std::vector::push_back(&mut game.players, player);

  // Add payment to pot
  let payment_balance = coin::into_balance(payment);
  balance::join(&mut game.pot, payment_balance);

  // Emit event
  let game_id = sui::object::uid_to_inner(&game.id);
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

// Player actions: fold, check, call, bet, raise
public entry fun player_action(
  game: &mut PokerGame,
  action: u8,
  amount: u64,
  ctx: &mut TxContext,
) {
  // Validate game state
  if (game.state < STATE_PRE_FLOP || game.state > STATE_RIVER) {
    abort EInvalidGameState
  };

  let player_addr = sui::tx_context::sender(ctx);
  let player_count = std::vector::length(&game.players);
  let player_index = find_player_index(game, player_addr);

  // Validate player
  if (player_index >= player_count) {
    abort EInvalidPlayer
  };
  if (player_index != game.current_player) {
    abort ENotYourTurn
  };

  let player = std::vector::borrow_mut(&mut game.players, player_index);
  if (player.is_folded) {
    abort EInvalidAction
  };

  // Process the action
  if (action == ACTION_FOLD) {
    player.is_folded = true;
  } else if (action == ACTION_CHECK) {
    if (game.current_bet != player.current_bet) {
      abort EInvalidAction
    };
  } else if (action == ACTION_CALL) {
    let call_amount = game.current_bet - player.current_bet;
    if (call_amount > player.balance) {
      abort EInvalidBet
    };
    player.balance = player.balance - call_amount;
    player.current_bet = game.current_bet;
    if (player.balance == 0) {
      player.is_all_in = true;
    }
  } else if (action == ACTION_BET || action == ACTION_RAISE) {
    // For a bet, there should be no current bet
    if (action == ACTION_BET) {
      if (game.current_bet != 0) {
        abort EInvalidAction
      };
    } else {
      // For a raise, there should be a current bet and the raise should be at least min_bet
      if (game.current_bet == 0) {
        abort EInvalidAction
      };
      if (amount < game.current_bet + game.min_bet) {
        abort EInvalidBet
      };
    };

    // Check if player has enough balance for bet/raise
    if (amount > player.balance + player.current_bet) {
      abort EInvalidBet
    };

    let additional_amount = amount - player.current_bet;
    player.balance = player.balance - additional_amount;
    player.current_bet = amount;
    game.current_bet = amount;
    game.last_raise_position = player_index;

    if (player.balance == 0) {
      player.is_all_in = true;
    }
  } else {
    abort EInvalidAction
  };

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

  // Collect bets into pot
  collect_bets(game);

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

fun collect_bets(_game: &mut PokerGame) {}

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
  // In a real implementation, this would evaluate hands and distribute the pot
  // For simplicity, we'll just find the single non-folded player or
  // simulate a simple hand evaluation

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

        // Update player balance instead of direct transfer
        // In a real game, we would use sui::transfer to send funds
        let p = game.players.borrow_mut(i);
        p.balance = p.balance + pot_amount;
        break
      };
      i = i + 1;
    }
  } else {
    // For a simple implementation, distribute pot equally among all active players // In a real implementation, this would evaluate poker hands
    let pot_amount = balance::value(&game.pot);
    let share = pot_amount / active_count;
    let mut i = 0;
    while (i < player_count && share > 0) {
      let player = game.players.borrow(i);
      if (!player.is_folded) {
        let winner_addr = player.addr;

        winners.push_back(winner_addr);
        amounts.push_back(share);

        // Update player balance instead of direct transfer
        let p = game.players.borrow_mut(i);
        p.balance = p.balance + share;
      };
      i = i + 1;
    }; // Handle any remaining dust in the pot (due to division)
    let remaining = balance::value(&game.pot);
    if (remaining > 0 && winners.length() > 0) {
      // Add remaining to first winner's share
      let mut first_winner_idx = 0;
      let mut j = 0;
      while (j < player_count) {
        let player = game.players.borrow(j);
        if (!player.is_folded) {
          first_winner_idx = j;
          break
        };
        j = j + 1;
      };

      let p = game.players.borrow_mut(first_winner_idx);
      p.balance = p.balance + remaining;
    }
  };

  // Emit game ended event
  let game_id = game.id.to_inner();
  sui::event::emit(GameEnded { game_id, winners, amounts });

  // Set game state to game over
  game.state = STATE_GAME_OVER;
}

// Hand evaluation would be implemented here in a full version of the contract
// For simplicity, we've omitted hand evaluation logic
