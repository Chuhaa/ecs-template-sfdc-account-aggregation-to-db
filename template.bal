import ballerina/io;
import ballerina/config;
import ballerinax/mysql;
import ballerina/log;
import ballerina/sql;
import ballerinax/sfdc;

sfdc:SalesforceConfiguration sfConfig = {
    baseUrl: config:getAsString("SF_EP_URL"),
    clientConfig: {
        accessToken: config:getAsString("SF_ACCESS_TOKEN"),
        refreshConfig: {
            clientId: config:getAsString("SF_CLIENT_ID"),
            clientSecret: config:getAsString("SF_CLIENT_SECRET"),
            refreshToken: config:getAsString("SF_REFRESH_TOKEN"),
            refreshUrl: config:getAsString("SF_REFRESH_URL")
        }
    }
};

sfdc:BaseClient baseClient = new (sfConfig);

mysql:Client mysqlClient = check new (user = config:getAsString("DB_USER"), password = config:getAsString("DB_PWD"));

public function main() {
    sql:ExecutionResult|sql:Error? result = mysqlClient->execute("CREATE DATABASE IF NOT EXISTS ESC_SFDC_TO_DB");
    sql:ParameterizedQuery insertQuery = 
    `CREATE TABLE IF NOT EXISTS ESC_SFDC_TO_DB.Temp(Id VARCHAR(300) UNIQUE, DbName VARCHAR(300));`;
    result = mysqlClient->execute(insertQuery);
    string queryStr = "SELECT Id, Name FROM Account";
    error|sfdc:BulkJob queryJob = baseClient->creatJob("query", "Account", "JSON");
    if (queryJob is sfdc:BulkJob) {
        error|sfdc:BatchInfo batch = queryJob->addBatch(queryStr);
        if (batch is sfdc:BatchInfo) {
            var batchResult = queryJob->getBatchResult(batch.id);
            if (batchResult is json) {
                json[]|error batchResultArr = <json[]>batchResult;
                if (batchResultArr is json[]) {
                    foreach var account in batchResultArr {
                        string id = account.Id.toString();
                        string name = account.Name.toString();
                        sql:ParameterizedQuery query = `INSERT INTO ESC_SFDC_TO_DB.Temp (Id, DbName) VALUES (${id}, ${
                        name})`;
                        result = mysqlClient->execute(<@untainted>query);
                    }
                } else {
                    log:printError(batchResultArr.toString());
                }
            } else if (batchResult is error) {
                log:printError(batchResult.message());
            } else {
                log:printError("Invalid Batch Result!");
            }
        } else {
            log:printError(batch.message());
        }
    } else {
        log:printError(queryJob.message());
    }
    getAggregation();
    result = mysqlClient->execute("DROP TABLE IF EXISTS ESC_SFDC_TO_DB.Temp");

}

function getAggregation() {
    sql:ParameterizedQuery query = 
    `SELECT Account.Id, Account.Name FROM ESC_SFDC_TO_DB.Account
            LEFT OUTER JOIN ESC_SFDC_TO_DB.Temp ON Account.Id=Temp.Id WHERE Temp.DbName IS NULL;`;
    stream<record { }, error> queryResult = mysqlClient->query(query, AccountAggregation);
    stream<AccountAggregation, sql:Error> streamDbData = <stream<AccountAggregation, sql:Error>>queryResult;

    query = 
    `SELECT Temp.Id, Account.Name, Temp.DbName FROM ESC_SFDC_TO_DB.Account
            RIGHT OUTER JOIN ESC_SFDC_TO_DB.Temp ON Account.Id=Temp.Id WHERE Account.Name IS NULL;`;
    queryResult = mysqlClient->query(query, AccountAggregation);
    stream<AccountAggregation, sql:Error> streamSfData = <stream<AccountAggregation, sql:Error>>queryResult;

    query = 
    `SELECT Account.Id, Account.Name, Temp.DbName FROM ESC_SFDC_TO_DB.Account
            INNER JOIN ESC_SFDC_TO_DB.Temp ON Account.Id=Temp.Id;`;
    queryResult = mysqlClient->query(query, AccountAggregation);
    stream<AccountAggregation, sql:Error> streamData = <stream<AccountAggregation, sql:Error>>queryResult;

    string targetFileName = "./target/out.csv";
    io:WritableCSVChannel|error wCsvChannel2 = io:openWritableCsvFile(targetFileName);

    if (wCsvChannel2 is io:WritableCSVChannel) {
        error? e;
        string[] title = ["Id", "DB Account Name", "SF Account Name"];
        writeDataToCSVChannel(wCsvChannel2, title);
        e = streamDbData.forEach(function(AccountAggregation account) {
            string[] rec = [account.id, account.name.toString(), account.dbName.toString()];
            writeDataToCSVChannel(wCsvChannel2, rec);
        });

        e = streamSfData.forEach(function(AccountAggregation account) {
            string[] rec = [account.id.toString(), account.name.toString(), account.dbName.
            toString()];
            writeDataToCSVChannel(wCsvChannel2, rec);
        });

        e = streamData.forEach(function(AccountAggregation account) {
            string[] rec = [account.id, account.name, account.dbName];
            io:println("Student ", account.id, " has a score of ", account.dbName);
            writeDataToCSVChannel(wCsvChannel2, rec);
        });
        closeWritableCSVChannel(wCsvChannel2);
    }
}

function closeWritableCSVChannel(io:WritableCSVChannel csvChannel) {
    var result = csvChannel.close();
    if (result is error) {
        log:printError("Error occurred while closing the channel: ", err = result);
    }
}

function writeDataToCSVChannel(io:WritableCSVChannel|error csvChannel, string[]... data) {
    if (csvChannel is io:WritableCSVChannel) {
        foreach var rec in data {
            var returnedVal = csvChannel.write(rec);
            if (returnedVal is error) {
                log:printError("Error occurred while writing to target file: ", err = returnedVal);
            }
        }
    }
}

public type Account record {|
    string id;
    string name;
|};

public type AccountAggregation record {|
    string id;
    string name;
    string dbName;
|};
