"""Pay calculation rules."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal


@dataclass(frozen=True)
class RateConfig:
    """Rates for one user. ``event_rates`` keys are lowercased event names."""

    default_rate: Decimal
    event_rates: dict[str, Decimal]
    overtime_after_hours: Decimal | None = None
    overtime_multiplier: Decimal = Decimal("1.5")
    currency: str = "SGD"
    default_break_hours: Decimal = Decimal("0")
    default_break_paid: bool = False

    def rate_for(self, event: str) -> Decimal:
        return self.event_rates.get(event.strip().lower(), self.default_rate)


def round_money(amount: Decimal) -> Decimal:
    return amount.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def calculate_pay(
    hours: float, event: str, config: RateConfig, rate_override: Decimal | None = None
) -> Decimal:
    """Pay for a shift, applying an overtime multiplier beyond a threshold."""
    worked = Decimal(str(hours))
    rate = config.rate_for(event) if rate_override is None else rate_override
    threshold = config.overtime_after_hours
    if threshold is None or worked <= threshold:
        return round_money(worked * rate)
    normal = threshold * rate
    overtime = (worked - threshold) * rate * config.overtime_multiplier
    return round_money(normal + overtime)
