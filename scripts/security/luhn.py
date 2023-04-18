#!/usr/bin/env python3

import argparse
import sys

# Returns true if given card number is valid
def checkLuhn(cardNo):
    nDigits = len(cardNo)
    nSum = 0
    isSecond = False

    for i in range(nDigits - 1, -1, -1):
        d = ord(cardNo[i]) - ord('0')

        if (isSecond == True):
            d = d * 2

        # We add two digits to handle cases that make two digits after
        # doubling
        nSum += d // 10
        nSum += d % 10

        isSecond = not isSecond

    if (nSum % 10 == 0):
        return True
    else:
        return False

def main(options):
    for cardno in options["cardnos"]:
        if (checkLuhn(cardno)):
            print("[+] " + cardno)
        else:
            print("[-] " + cardno)

def parse():
    parser = argparse.ArgumentParser(
        add_help=False,
        description="""
        This tool will determine if a card number is valid using the
        Luhn algorithm.
        """
    )
    parser.add_argument(
        "-h",
        "--help",
        action="store_true",
        help="Display this help message."
    )
    parser.add_argument(
        "cardno",
        help="Card number to check.",
        nargs="*"
    )
    args = parser.parse_args()

    options = {"cardnos": args.cardno}

    if (args.help):
        parser.print_help()
        sys.exit(0)

    return options

if __name__ == "__main__":
    options = parse()
    main(options)
