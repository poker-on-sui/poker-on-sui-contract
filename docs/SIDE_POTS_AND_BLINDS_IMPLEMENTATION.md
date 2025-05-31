# Side Pot Handling and Blinds Rotation Implementation

This document describes the implementation of side pot handling for all-in scenarios and blinds rotation system in the Texas Hold'em poker game.

## Features Implemented

### 1. Side Pot Handling for All-In Scenarios

**Overview**: When players go all-in with different amounts, the system creates separate pots (main pot and side pots) to ensure players can only win up to the amount they contributed.

**Key Components:**

#### SidePot Struct

```move
public struct SidePot has drop, store {
  amount: u64,
  eligible_players: vector<u64>, // Player indices eligible for this pot
}
```

#### Player Struct Enhancement

Added `total_contributed` field to track total amount each player has contributed across all betting rounds:

```move
public struct Player has drop, store {
  addr: address,
  cards: vector<Card>,
  balance: u64,
  current_bet: u64,
  total_contributed: u64, // NEW: Total amount contributed to all pots this hand
  is_folded: bool,
  is_all_in: bool,
}
```

#### PokerGame Struct Enhancement

Added `side_pots` field to store side pot information:

```move
public struct PokerGame has key {
  // ...existing fields...
  side_pots: vector<SidePot>,
  // ...existing fields...
}
```

#### Side Pot Creation Logic

The `create_side_pots()` function:

1. Collects all unique contribution levels from active players
2. Sorts them in ascending order
3. Creates a side pot for each level with eligible players
4. Calculates pot amounts based on contribution differences

#### Enhanced Pot Distribution

The `distribute_pot()` function now:

1. Creates side pots based on player contributions
2. Evaluates hands for each side pot's eligible players
3. Distributes each side pot separately to winners
4. Handles multiple winners and remainder amounts correctly

### 2. Blinds Rotation System

**Overview**: The dealer position rotates after each hand, and small/big blind positions move accordingly.

**Key Components:**

#### New Hand Management

```move
public entry fun start_new_hand(game: &mut PokerGame, ctx: &mut TxContext)
```

This function:

1. Validates that the current game is over
2. Rotates the dealer position: `(dealer_position + 1) % player_count`
3. Resets all game state for the new hand
4. Redistributes cards and posts new blinds
5. Sets the correct turn order for the new hand

#### Game State Reset

The `reset_for_new_hand()` function resets:

- Player cards, bets, and contributions
- Community cards and side pots
- Game betting state and turn tracking

#### Enhanced Blind Collection

Updated `collect_blinds()` to properly track `total_contributed` for blind posts.

### 3. Enhanced Betting Functions

All betting functions (`call`, `bet`, `raise`) now properly track `total_contributed`:

```move
player.total_contributed = player.total_contributed + additional_amount;
```

This ensures accurate side pot calculations when players go all-in at different amounts.

## Technical Implementation Details

### Side Pot Algorithm

1. **Contribution Tracking**: Each player's `total_contributed` tracks cumulative betting across all rounds
2. **Level Sorting**: Unique contribution levels are sorted to create hierarchical pots
3. **Eligibility**: Players are eligible for pots up to their contribution level
4. **Distribution**: Each side pot is evaluated and distributed independently

### Blinds Rotation Algorithm

1. **Position Tracking**: Dealer position increments each hand
2. **Blind Positions**:
   - Small blind: `(dealer_position + 1) % player_count`
   - Big blind: `(dealer_position + 2) % player_count`
3. **Turn Order**: First to act pre-flop: `(dealer_position + 3) % player_count`

## Example Scenarios

### Side Pot Example

- Player A: All-in for 100 chips
- Player B: All-in for 200 chips  
- Player C: Bets 300 chips

**Result:**

- Main pot: 300 chips (100 from each) - all players eligible
- Side pot 1: 200 chips (100 from B and C) - only B and C eligible
- Side pot 2: 100 chips (remaining from C) - only C eligible

### Blinds Rotation Example

**Hand 1**: PLAYER0 (dealer), PLAYER1 (SB), PLAYER2 (BB)
**Hand 2**: PLAYER1 (dealer), PLAYER2 (SB), PLAYER0 (BB)
**Hand 3**: PLAYER2 (dealer), PLAYER0 (SB), PLAYER1 (BB)

## Testing

Comprehensive tests implemented:

- `test_side_pot_all_in_scenario`: Basic side pot functionality
- `test_side_pot_multiple_all_ins`: Complex multiple all-in scenarios
- `test_dealer_rotation_multiple_hands`: Blinds rotation across hands
- All existing tests updated for new player turn order logic

## Code Quality

- Follows Move language best practices
- Maintains consistent error handling with hex codes
- Preserves existing API compatibility
- Comprehensive documentation and comments
- Proper event emission for state changes

## Future Enhancements

Potential improvements:

1. More sophisticated side pot visualization in events
2. Support for antes in addition to blinds
3. Automatic game continuation for tournament play
4. Player elimination and seat management
