import snowflake.connector
import pytest

def test_smoke_test_snowflake_offline():
    """Test that Snowflake connector properly raises an error with fake credentials."""
    with pytest.raises(snowflake.connector.errors.Error):
        snowflake.connector.connect(
            user="fake_user",
            password="fake_password",
            account="fake_account"
        )